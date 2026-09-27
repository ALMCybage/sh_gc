variable "project_id" {
  type        = string
  description = "GCP project id. One project per environment."
}

variable "environment" {
  type = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "platform_name" {
  type    = string
  default = "sequifi"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "base_domain" {
  type        = string
  description = "Tenants are subdomains of this, e.g. acme.sequifi.com."
}

# --- tenants ---------------------------------------------------------------

variable "tenants" {
  type = map(object({
    name   = string
    schema = string
  }))
  description = <<-EOT
    The tenant registry, keyed by tenant id. This is the source of truth: it produces
    the Cloud SQL schemas, the URL map host rules, the certificate SANs and the
    TENANTS_JSON both services read.

    Onboarding a tenant is an entry here, an apply, a DNS record, and a
    tenants:migrate run.
  EOT

  default = {
    acme        = { name = "Acme Corp", schema = "tenant_acme" }
    whiteknight = { name = "White Knight", schema = "tenant_whiteknight" }
    frdm        = { name = "FRDM", schema = "tenant_frdm" }
  }

  validation {
    condition = alltrue([
      for id, cfg in var.tenants : can(regex("^[a-z0-9_]+$", cfg.schema))
    ])
    error_message = "Tenant schema names must be lowercase alphanumeric with underscores: they are interpolated into a MySQL DSN and cannot be bound as a parameter."
  }
}

# --- namespaces ------------------------------------------------------------

variable "app_namespace" {
  type    = string
  default = "sequifi"
}

variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

# --- network ---------------------------------------------------------------

variable "subnet_cidr" {
  type    = string
  default = "10.10.0.0/20"
}

variable "pods_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "services_cidr" {
  type    = string
  default = "10.30.0.0/20"
}

variable "master_cidr" {
  type    = string
  default = "172.16.0.0/28"
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  description = "Restrict Kubernetes API access. Leaving this empty blocks everything except Google-internal access."
  default     = []
}

# --- GKE -------------------------------------------------------------------

variable "gke_release_channel" {
  type    = string
  default = "REGULAR"
}

variable "usage_export_dataset" {
  type        = string
  description = "BigQuery dataset for per-namespace cost attribution."
  default     = null
}

# --- Cloud SQL -------------------------------------------------------------

variable "sql_tier" {
  type    = string
  default = "db-custom-4-16384"
}

variable "sql_replica_tier" {
  type    = string
  default = "db-custom-2-8192"
}

variable "sql_availability_type" {
  type    = string
  default = "REGIONAL"
}

variable "sql_disk_size_gb" {
  type    = number
  default = 50
}

variable "sql_max_connections" {
  type        = number
  description = "Must exceed pods x tenants x per-tenant pool size. See the comment in modules/cloudsql."
  default     = 2000
}

variable "sql_create_read_replica" {
  type    = bool
  default = true
}

variable "sql_retained_backups" {
  type    = number
  default = 30
}

# --- Memorystore -----------------------------------------------------------

variable "redis_tier" {
  type    = string
  default = "STANDARD_HA"
}

variable "redis_memory_gb" {
  type    = number
  default = 5
}

# --- Firestore -------------------------------------------------------------

variable "firestore_location" {
  type        = string
  description = "Cannot be changed after creation."
  default     = "us-central1"
}

# --- Pub/Sub ---------------------------------------------------------------

variable "max_delivery_attempts" {
  type        = number
  description = "Keep in step with the worker's WORKER_MAX_RETRIES."
  default     = 5
}

# --- Edge ------------------------------------------------------------------

variable "frontend_bucket" {
  type        = string
  description = "Globally unique GCS bucket name for the built SPA."
}

variable "use_wildcard_certificate" {
  type        = bool
  description = "Required past ~100 tenants; see modules/edge/variables.tf."
  default     = false
}

variable "api_neg_self_links" {
  type        = list(string)
  description = "Populated on the second apply, after the workload has created the NEGs."
  default     = []
}

variable "waf_preview_only" {
  type        = bool
  description = "Start true. Turning OWASP rules straight to deny on a JSON API blocks real traffic."
  default     = true
}

variable "edge_rate_limit_per_minute" {
  type    = number
  default = 1000
}

# --- Observability ---------------------------------------------------------

variable "pagerduty_service_key" {
  type      = string
  default   = null
  sensitive = true
}

variable "slack_webhook_url" {
  type      = string
  default   = null
  sensitive = true
}

variable "slack_channel" {
  type    = string
  default = "#sequifi-alerts"
}

variable "ops_email" {
  type    = string
  default = null
}

variable "runbook_base_url" {
  type    = string
  default = "https://github.com/your-org/sequifi/blob/main/docs/runbook"
}

variable "create_slos" {
  type    = bool
  default = true
}

variable "availability_slo" {
  type    = number
  default = 0.999
}

# --- CI --------------------------------------------------------------------

variable "github_repository" {
  type        = string
  description = "owner/repo for GitHub Actions OIDC federation. Null disables the CI identity."
  default     = null
}

# --- safety ----------------------------------------------------------------

variable "deletion_protection" {
  type        = bool
  description = <<-EOT
    Guards the cluster, the database and the Firestore database against
    `terraform destroy`. True in prod, false in dev so a dev environment can actually
    be torn down.
  EOT
  default     = true
}

variable "labels" {
  type    = map(string)
  default = {}
}
