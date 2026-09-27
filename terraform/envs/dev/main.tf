/**
 * Dev environment.
 *
 * Deliberately cheaper and less protected than prod:
 *   - zonal Cloud SQL, no read replica, smaller tiers
 *   - deletion protection off, so it can actually be torn down
 *   - no PagerDuty: a dev cluster paging on-call is how alerting gets muted
 *   - WAF in preview, so rule tuning happens here rather than in prod
 */

module "stack" {
  source = "../../stack"

  project_id  = var.project_id
  environment = "dev"
  region      = var.region
  base_domain = var.base_domain

  frontend_bucket = "${var.project_id}-sequifi-dev-frontend"

  # Two tenants is enough to prove isolation without paying for three schemas.
  tenants = {
    acme        = { name = "Acme Corp (dev)", schema = "tenant_acme" }
    whiteknight = { name = "White Knight (dev)", schema = "tenant_whiteknight" }
  }

  # Smallest sensible footprint.
  sql_tier                = "db-custom-1-3840"
  sql_availability_type   = "ZONAL"
  sql_create_read_replica = false
  sql_disk_size_gb        = 20
  sql_max_connections     = 200
  sql_retained_backups    = 7

  redis_tier      = "BASIC"
  redis_memory_gb = 1

  # Lets `terraform destroy` work. Never set this in prod.
  deletion_protection = false

  master_authorized_networks = var.master_authorized_networks

  # Slack only. No paging from dev.
  slack_webhook_url = var.slack_webhook_url
  create_slos       = false

  waf_preview_only  = true
  github_repository = var.github_repository

  api_neg_self_links = var.api_neg_self_links

  labels = {
    cost_center = "engineering"
  }
}
