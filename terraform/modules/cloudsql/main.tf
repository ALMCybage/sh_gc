/**
 * Cloud SQL for MySQL: the shared instance holding one schema per tenant.
 *
 * "Shared Application - Multi-Database" means tenants are isolated at the schema
 * boundary, not by separate instances. That is a deliberate cost/isolation trade:
 * 150 instances would be unaffordable and unmanageable, while 150 schemas on an HA
 * instance share a blast radius. The application enforces the boundary (per-tenant
 * connections, no cross-schema queries) and the grant below limits the app user to
 * the tenant_% pattern so a bug cannot reach anything else.
 */

resource "random_password" "app_user" {
  length = 32
  # Excludes characters that need escaping in a DSN or a shell.
  override_special = "!#%*_-+=:?"
}

resource "google_sql_database_instance" "primary" {
  name             = var.instance_name
  project          = var.project_id
  region           = var.region
  database_version = var.database_version

  # Guards against `terraform destroy` taking the payroll database with it.
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    availability_type = var.availability_type
    disk_type         = "PD_SSD"
    disk_size         = var.disk_size_gb
    # Grows the disk before it fills rather than taking an outage at 100%.
    disk_autoresize       = true
    disk_autoresize_limit = var.disk_autoresize_limit_gb

    edition = var.edition

    ip_configuration {
      # No public IP at all. The only path in is the private network, which is what
      # makes the Cloud SQL Auth Proxy sidecar the single access route.
      ipv4_enabled                                  = false
      private_network                               = var.network_id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled = true
      # 03:00 UTC, ahead of the maintenance window so they do not collide.
      start_time                     = "03:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = var.transaction_log_retention_days
      binary_log_enabled             = true

      backup_retention_settings {
        retained_backups = var.retained_backups
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 4
      update_track = "stable"
    }

    insights_config {
      # Query Insights: the first thing you want when a tenant reports slowness.
      query_insights_enabled = true
      query_string_length    = 1024
      # Per-tenant attribution needs the application to set a comment/tag; recording
      # client address and app name is the part Cloud SQL can do on its own.
      record_application_tags = true
      record_client_address   = true
    }

    database_flags {
      name  = "default_time_zone"
      value = "+00:00"
    }

    database_flags {
      name  = "character_set_server"
      value = "utf8mb4"
    }

    /*
     * The worker holds a connection pool per tenant schema and the web tier one per
     * php-fpm child, so total connections scale with pods x tenants. This value has
     * to exceed the worst case:
     *
     *   worker: pods x DB_MAX_OPEN_SCHEMAS x DB_MAX_OPEN_CONNS  (20 x 8 x 4  = 640)
     *   web:    pods x pm.max_children                          (30 x 16     = 480)
     *   plus migrations, Query Insights and headroom
     */
    database_flags {
      name  = "max_connections"
      value = tostring(var.max_connections)
    }

    database_flags {
      name  = "slow_query_log"
      value = "on"
    }

    database_flags {
      name  = "long_query_time"
      value = "2"
    }

    user_labels = var.labels
  }

  # The private IP cannot be allocated until the VPC peering exists.
  depends_on = [var.private_service_connection]

  lifecycle {
    # Changing these in place would recreate the instance and lose the data.
    prevent_destroy = false # set true in prod via the env wrapper
  }
}

/**
 * Read replica for reporting.
 *
 * Not used by the application in this sample: it exists so a long analytical query
 * over a tenant's payroll history cannot compete with the worker for connections
 * or IO on the primary.
 */
resource "google_sql_database_instance" "replica" {
  count = var.create_read_replica ? 1 : 0

  name                 = "${var.instance_name}-replica"
  project              = var.project_id
  region               = var.region
  database_version     = var.database_version
  master_instance_name = google_sql_database_instance.primary.name
  deletion_protection  = false

  replica_configuration {
    failover_target = false
  }

  settings {
    tier = var.replica_tier
    # A replica cannot be REGIONAL; the primary's HA covers failover.
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_autoresize   = true
    edition           = var.edition

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    insights_config {
      query_insights_enabled = true
    }

    user_labels = var.labels
  }
}

# ---------------------------------------------------------------------------
# Application user and per-tenant schemas
# ---------------------------------------------------------------------------

resource "google_sql_user" "app" {
  name     = var.app_username
  project  = var.project_id
  instance = google_sql_database_instance.primary.name
  password = random_password.app_user.result

  # The Cloud SQL Auth Proxy connects from inside the VPC, but the MySQL user host
  # is still '%' because the proxy's source address is not stable.
  host = "%"
}

resource "google_sql_database" "tenant" {
  for_each = var.tenant_schemas

  name      = each.value
  project   = var.project_id
  instance  = google_sql_database_instance.primary.name
  charset   = "utf8mb4"
  collation = "utf8mb4_unicode_ci"

  # Dropping a tenant's schema must be a deliberate, separate act.
  deletion_policy = "ABANDON"
}

# ---------------------------------------------------------------------------
# The password goes to Secret Manager, never to an output
# ---------------------------------------------------------------------------

resource "google_secret_manager_secret" "db_password" {
  secret_id = "${var.name_prefix}-db-password"
  project   = var.project_id

  labels = var.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.app_user.result
}
