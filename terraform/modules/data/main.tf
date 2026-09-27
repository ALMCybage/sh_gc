/**
 * The remaining managed data services: Memorystore, Firestore, Pub/Sub and
 * Artifact Registry. Grouped into one module because they are small, have no
 * interdependencies, and splitting them further would add wiring without adding
 * clarity.
 */

# ---------------------------------------------------------------------------
# Memorystore: sessions, application cache, idempotency claims
# ---------------------------------------------------------------------------

/**
 * STANDARD_HA, not BASIC.
 *
 * Sessions live here, so losing the instance signs out every user in every tenant.
 * Idempotency claims live here too, which matters more than it sounds: losing them
 * mid-retry means a client's second attempt is treated as a new operation and could
 * queue a duplicate payroll run.
 */
resource "google_redis_instance" "cache" {
  name    = "${var.name_prefix}-cache"
  project = var.project_id
  region  = var.region

  tier           = var.redis_tier
  memory_size_gb = var.redis_memory_gb
  redis_version  = var.redis_version

  authorized_network = var.network_id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  # AUTH plus in-transit encryption: Redis holds session material, so neither is
  # optional even on a private network.
  auth_enabled            = true
  transit_encryption_mode = "SERVER_AUTHENTICATION"

  redis_configs = {
    # Sessions and cache share this instance, so eviction has to be LRU rather
    # than noeviction (which would start refusing writes when full).
    maxmemory-policy = "allkeys-lru"
    # Notify on expiry so a future session-revocation feature has an event source.
    notify-keyspace-events = "Ex"
  }

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"

      start_time {
        hours   = 5
        minutes = 0
      }
    }
  }

  persistence_config {
    # RDB snapshots. Not durability for sessions (losing an hour of sessions is
    # survivable) but it shortens recovery after a failover.
    persistence_mode    = "RDB"
    rdb_snapshot_period = "TWELVE_HOURS"
  }

  labels     = var.labels
  depends_on = [var.private_service_connection]
}

resource "google_secret_manager_secret" "redis_auth" {
  secret_id = "${var.name_prefix}-redis-auth"
  project   = var.project_id
  labels    = var.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "redis_auth" {
  secret      = google_secret_manager_secret.redis_auth.id
  secret_data = google_redis_instance.cache.auth_string
}

# ---------------------------------------------------------------------------
# Firestore: API request status tracking
# ---------------------------------------------------------------------------

/**
 * Native mode, not Datastore mode.
 *
 * The status documents are read by request id and (potentially) listened to in
 * real time; Native mode is the one that supports that. Documents are keyed
 * "<tenant>__<request>" and carry tenant_id, so the collection is partitioned per
 * tenant.
 */
resource "google_firestore_database" "default" {
  project     = var.project_id
  name        = "(default)"
  location_id = var.firestore_location
  type        = "FIRESTORE_NATIVE"

  concurrency_mode = "OPTIMISTIC"
  # Both services write to the same document (web tier seeds it, worker merges
  # progress), so point-in-time recovery is worth having if a bad deploy corrupts
  # statuses.
  point_in_time_recovery_enablement = "POINT_IN_TIME_RECOVERY_ENABLED"
  app_engine_integration_mode       = "DISABLED"

  delete_protection_state = var.firestore_delete_protection ? "DELETE_PROTECTION_ENABLED" : "DELETE_PROTECTION_DISABLED"

  depends_on = [var.api_dependencies]
}

/**
 * TTL on the status documents.
 *
 * Statuses are operational data, not a record of the work - the payroll run itself
 * lives in Cloud SQL and the audit trail in audit_logs. Without a TTL the
 * collection grows forever and every tenant pays for it.
 */
resource "google_firestore_field" "status_ttl" {
  project    = var.project_id
  database   = google_firestore_database.default.name
  collection = var.firestore_collection
  field      = "expires_at"

  ttl_config {}
}

# Supports "show me this tenant's recent requests" without a collection scan.
resource "google_firestore_index" "tenant_recent" {
  project    = var.project_id
  database   = google_firestore_database.default.name
  collection = var.firestore_collection

  fields {
    field_path = "tenant_id"
    order      = "ASCENDING"
  }

  fields {
    field_path = "updated_at"
    order      = "DESCENDING"
  }
}

# ---------------------------------------------------------------------------
# Pub/Sub: the async decoupling point
# ---------------------------------------------------------------------------

resource "google_pubsub_topic" "dead_letter" {
  name    = var.dlq_topic
  project = var.project_id
  labels  = var.labels

  message_retention_duration = "604800s" # 7 days
}

/**
 * Something must be subscribed to the dead-letter topic.
 *
 * A topic with no subscription discards everything published to it, so poison
 * messages would vanish silently - the worst possible outcome for a failed payroll
 * run. This subscription is what the DLQ-depth alert measures and what an operator
 * pulls from when investigating.
 */
resource "google_pubsub_subscription" "dead_letter_inspect" {
  name    = "${var.dlq_topic}-inspect"
  project = var.project_id
  topic   = google_pubsub_topic.dead_letter.id
  labels  = var.labels

  message_retention_duration = "604800s"
  retain_acked_messages      = false
  ack_deadline_seconds       = 60
  # Never expire: an unattended DLQ subscription disappearing is how evidence gets
  # lost between an incident and its investigation.
  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_topic" "work" {
  for_each = var.topics

  name    = each.value.topic
  project = var.project_id
  labels  = merge(var.labels, { flow = each.key })

  message_retention_duration = "86600s"
}

resource "google_pubsub_subscription" "worker" {
  for_each = var.topics

  name    = each.value.subscription
  project = var.project_id
  topic   = google_pubsub_topic.work[each.key].id
  labels  = merge(var.labels, { flow = each.key })

  # 60s to start; the worker extends the deadline while a long payroll run is in
  # flight (PUBSUB_ACK_EXTENSION), so this only needs to cover the fast case.
  ack_deadline_seconds = 60

  # A week of retention means an outage of a few days still leaves the work
  # recoverable rather than lost.
  message_retention_duration = "604800s"
  retain_acked_messages      = false

  expiration_policy {
    ttl = ""
  }

  /**
   * Dead-letter after 5 attempts.
   *
   * A message that keeps failing is a bug, not bad luck. Retrying it forever keeps
   * the subscription backlog hot, which keeps the HPA scaled up, which means paying
   * for pods to fail repeatedly.
   */
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = var.max_delivery_attempts
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
}

/**
 * Pub/Sub needs permission on the subscription and the dead-letter topic to move
 * messages. Without these two bindings, dead-lettering silently does not happen and
 * the message is retried forever instead.
 */
data "google_project" "current" {
  project_id = var.project_id
}

locals {
  pubsub_service_agent = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.dead_letter.name
  role    = "roles/pubsub.publisher"
  member  = local.pubsub_service_agent
}

resource "google_pubsub_subscription_iam_member" "dead_letter_subscriber" {
  for_each = var.topics

  project      = var.project_id
  subscription = google_pubsub_subscription.worker[each.key].name
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_service_agent
}

# ---------------------------------------------------------------------------
# Artifact Registry
# ---------------------------------------------------------------------------

resource "google_artifact_registry_repository" "images" {
  provider = google-beta

  location      = var.region
  project       = var.project_id
  repository_id = var.artifact_repository
  format        = "DOCKER"
  description   = "Sequifi service images"
  labels        = var.labels

  docker_config {
    # Published tags cannot be moved. Deploys reference a git SHA, and an immutable
    # tag means "the image that was tested" and "the image that is running" cannot
    # diverge underneath you.
    immutable_tags = true
  }

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent-releases"
    action = "KEEP"

    most_recent_versions {
      keep_count = 20
    }
  }

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"

    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s" # 7 days
    }
  }

  depends_on = [var.api_dependencies]
}

# ---------------------------------------------------------------------------
# Frontend bucket: the static React tier
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "frontend" {
  name     = var.frontend_bucket
  project  = var.project_id
  location = var.region

  uniform_bucket_level_access = true
  force_destroy               = var.frontend_bucket_force_destroy
  labels                      = var.labels

  website {
    main_page_suffix = "index.html"
    # SPA routing: an unknown path is a client-side route, so serve index.html and
    # let React resolve it. Without this, /payroll/<uuid> 404s on a cold load.
    not_found_page = "index.html"
  }

  versioning {
    # Cheap insurance: a bad frontend deploy can be rolled back by restoring the
    # previous index.html rather than rebuilding.
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 10
    }

    action {
      type = "Delete"
    }
  }

  cors {
    origin          = var.frontend_cors_origins
    method          = ["GET", "HEAD"]
    response_header = ["Content-Type", "Cache-Control"]
    max_age_seconds = 3600
  }
}

/**
 * The bundle is served through the load balancer's backend bucket, so the objects
 * have to be publicly readable. There is nothing secret in a client bundle - the
 * API is what enforces authorisation.
 */
resource "google_storage_bucket_iam_member" "frontend_public" {
  bucket = google_storage_bucket.frontend.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}
