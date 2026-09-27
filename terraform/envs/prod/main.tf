/**
 * Production environment.
 *
 * Differences from dev, and why each one exists:
 *   - REGIONAL Cloud SQL: an automatic failover replica in a second zone. Payroll
 *     data cannot depend on one zone staying up.
 *   - Read replica: keeps analytical queries off the primary, so a reporting query
 *     cannot starve the worker of connections.
 *   - STANDARD_HA Memorystore: sessions and idempotency claims live there. Losing
 *     the instance signs out every tenant and, worse, loses in-flight idempotency
 *     claims - which is how a retry turns into a duplicate payroll run.
 *   - deletion_protection: on, everywhere it exists.
 *   - PagerDuty: the [PAGE] policies only exist when a key is present.
 *   - Wildcard certificate: past ~100 tenants a classic managed cert runs out of
 *     SANs, and onboarding should be a DNS record rather than a certificate change.
 *   - master_authorized_networks is required, not optional.
 */

module "stack" {
  source = "../../stack"

  project_id  = var.project_id
  environment = "prod"
  region      = var.region
  base_domain = var.base_domain

  frontend_bucket = "${var.project_id}-sequifi-frontend"

  tenants = var.tenants

  # HA and headroom.
  sql_tier                = "db-custom-4-16384"
  sql_replica_tier        = "db-custom-2-8192"
  sql_availability_type   = "REGIONAL"
  sql_create_read_replica = true
  sql_disk_size_gb        = 100

  /*
   * Sized from the worst case, not a guess:
   *   worker: 20 pods x 8 schemas x 4 conns = 640
   *   web:    30 pods x 16 fpm children     = 480
   *   migrations, Query Insights, headroom  = ~380
   */
  sql_max_connections  = 2000
  sql_retained_backups = 30

  redis_tier      = "STANDARD_HA"
  redis_memory_gb = 5

  deletion_protection = true

  # Not optional in prod: an unrestricted control plane endpoint means anyone on the
  # internet can reach the API server with only IAM in front of it.
  master_authorized_networks = var.master_authorized_networks

  # STABLE, not REGULAR: fewer, better-tested upgrades under a payroll workload.
  gke_release_channel = "STABLE"

  use_wildcard_certificate = true

  # Tune in dev, enforce in prod.
  waf_preview_only           = false
  edge_rate_limit_per_minute = 2000

  pagerduty_service_key = var.pagerduty_service_key
  slack_webhook_url     = var.slack_webhook_url
  ops_email             = var.ops_email
  runbook_base_url      = var.runbook_base_url

  create_slos      = true
  availability_slo = 0.999

  usage_export_dataset = var.usage_export_dataset
  github_repository    = var.github_repository

  api_neg_self_links = var.api_neg_self_links

  labels = {
    cost_center = "platform"
    compliance  = "payroll"
  }
}

/**
 * Two prod guardrails are enforced by the variable definitions rather than by a
 * check resource:
 *
 *   - pagerduty_service_key has no default, so a prod apply cannot proceed without
 *     one. A prod environment whose critical alerts go nowhere looks healthy right
 *     up until the first incident.
 *   - master_authorized_networks has no default and is validated to be non-empty,
 *     so the control plane endpoint cannot be left open to the internet.
 *
 * See variables.tf.
 */
