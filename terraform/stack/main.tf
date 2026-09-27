/**
 * The environment blueprint.
 *
 * One composition, instantiated per environment from terraform/envs/*. Keeping it
 * here rather than duplicating a root module per environment means dev and prod
 * cannot drift structurally - only their inputs differ, and the differences are
 * visible in one tfvars file each.
 */

locals {
  name_prefix = "${var.platform_name}-${var.environment}"

  labels = merge(var.labels, {
    platform    = var.platform_name
    environment = var.environment
    managed_by  = "terraform"
  })

  # Tenant hostnames the edge answers on. Only used when not on a wildcard
  # certificate; with a wildcard the URL map still needs the host list, so it is
  # derived either way.
  tenant_domains = [for id in keys(var.tenants) : "${id}.${var.base_domain}"]

  tenant_schemas = { for id, cfg in var.tenants : id => cfg.schema }

  # Shared by both services. This is the single source of truth for the registry;
  # the built-in defaults in config/tenancy.php and registry.go are only fallbacks.
  tenants_json = jsonencode({
    for id, cfg in var.tenants : id => {
      name     = cfg.name
      database = cfg.schema
      domain   = "${id}.${var.base_domain}"
    }
  })
}

# ---------------------------------------------------------------------------
# APIs
#
# Everything below depends on these. Enabling them inside Terraform rather than by
# hand means a fresh project can be stood up from an empty state.
# ---------------------------------------------------------------------------

resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "sqladmin.googleapis.com",
    "redis.googleapis.com",
    "pubsub.googleapis.com",
    "firestore.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "cloudtrace.googleapis.com",
    "servicenetworking.googleapis.com",
    "certificatemanager.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
  ])

  project = var.project_id
  service = each.value

  # Leave APIs enabled on destroy: disabling them can break unrelated resources in
  # the same project, and re-enabling is slow.
  disable_on_destroy         = false
  disable_dependent_services = false
}

# ---------------------------------------------------------------------------
# Foundation
# ---------------------------------------------------------------------------

module "network" {
  source = "../modules/network"

  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix

  subnet_cidr   = var.subnet_cidr
  pods_cidr     = var.pods_cidr
  services_cidr = var.services_cidr

  depends_on = [google_project_service.required]
}

module "gke" {
  source = "../modules/gke"

  project_id   = var.project_id
  region       = var.region
  cluster_name = "${local.name_prefix}-autopilot"

  network_id          = module.network.network_id
  subnet_id           = module.network.subnet_id
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name

  master_cidr                = var.master_cidr
  master_authorized_networks = var.master_authorized_networks
  release_channel            = var.gke_release_channel
  deletion_protection        = var.deletion_protection
  usage_export_dataset       = var.usage_export_dataset

  labels           = local.labels
  api_dependencies = google_project_service.required
}

# ---------------------------------------------------------------------------
# Data services
# ---------------------------------------------------------------------------

module "cloudsql" {
  source = "../modules/cloudsql"

  project_id    = var.project_id
  region        = var.region
  name_prefix   = local.name_prefix
  instance_name = "${local.name_prefix}-mysql"

  network_id                 = module.network.network_id
  private_service_connection = module.network.private_service_connection

  tier                = var.sql_tier
  replica_tier        = var.sql_replica_tier
  availability_type   = var.sql_availability_type
  disk_size_gb        = var.sql_disk_size_gb
  max_connections     = var.sql_max_connections
  create_read_replica = var.sql_create_read_replica
  deletion_protection = var.deletion_protection
  retained_backups    = var.sql_retained_backups

  tenant_schemas = local.tenant_schemas
  labels         = local.labels
}

module "data" {
  source = "../modules/data"

  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix

  network_id                 = module.network.network_id
  private_service_connection = module.network.private_service_connection

  redis_tier      = var.redis_tier
  redis_memory_gb = var.redis_memory_gb

  firestore_location          = var.firestore_location
  firestore_delete_protection = var.deletion_protection

  max_delivery_attempts = var.max_delivery_attempts

  frontend_bucket               = var.frontend_bucket
  frontend_bucket_force_destroy = !var.deletion_protection

  labels           = local.labels
  api_dependencies = google_project_service.required
}

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

module "iam" {
  source = "../modules/iam"

  project_id  = var.project_id
  name_prefix = local.name_prefix

  app_namespace    = var.app_namespace
  argocd_namespace = var.argocd_namespace

  # Scoped per secret, not project-wide, so a new secret is not automatically
  # readable by every workload.
  web_api_secret_ids = [
    module.cloudsql.db_password_secret_id,
    module.data.redis_auth_secret_id,
    google_secret_manager_secret.app_key.secret_id,
  ]

  worker_secret_ids = [
    module.cloudsql.db_password_secret_id,
  ]

  github_repository = var.github_repository
}

/**
 * Laravel's APP_KEY.
 *
 * Generated here so it exists before the first deploy and is identical across every
 * pod. It has to be: it encrypts session cookies, so pods with different keys would
 * reject each other's sessions and users would be signed out at random depending on
 * which pod answered.
 */
resource "random_id" "app_key" {
  byte_length = 32
}

resource "google_secret_manager_secret" "app_key" {
  secret_id = "${local.name_prefix}-app-key"
  project   = var.project_id
  labels    = local.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "app_key" {
  secret      = google_secret_manager_secret.app_key.id
  secret_data = "base64:${random_id.app_key.b64_std}"
}

# ---------------------------------------------------------------------------
# Edge
# ---------------------------------------------------------------------------

module "edge" {
  source = "../modules/edge"

  project_id  = var.project_id
  name_prefix = local.name_prefix

  base_domain              = var.base_domain
  domains                  = local.tenant_domains
  use_wildcard_certificate = var.use_wildcard_certificate

  frontend_bucket = module.data.frontend_bucket

  # Empty on the first apply: the NEGs are created by the Kubernetes Service, which
  # does not exist until the workload is deployed. See bootstrap/README.md for the
  # ordering.
  api_neg_self_links = var.api_neg_self_links

  waf_preview_only      = var.waf_preview_only
  rate_limit_per_minute = var.edge_rate_limit_per_minute
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

module "monitoring" {
  source = "../modules/monitoring"

  project_id    = var.project_id
  name_prefix   = local.name_prefix
  app_namespace = var.app_namespace

  pagerduty_service_key = var.pagerduty_service_key
  slack_webhook_url     = var.slack_webhook_url
  slack_channel         = var.slack_channel
  ops_email             = var.ops_email
  runbook_base_url      = var.runbook_base_url

  sql_instance    = module.cloudsql.instance_name
  max_connections = var.sql_max_connections

  worker_subscriptions     = values(module.data.subscriptions)
  dead_letter_subscription = module.data.dead_letter_subscription
  max_delivery_attempts    = var.max_delivery_attempts

  uptime_check_host = length(local.tenant_domains) > 0 ? local.tenant_domains[0] : null

  create_slos      = var.create_slos
  availability_slo = var.availability_slo
}
