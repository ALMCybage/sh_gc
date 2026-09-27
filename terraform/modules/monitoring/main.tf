/**
 * Notification channels, alert policies and SLOs.
 *
 * Two principles drive what is here:
 *
 * 1. Every alert is actionable and routed by consequence. Anything that pages
 *    somebody at 3am has to be something a human can fix at 3am; everything else
 *    goes to Slack. An alert nobody can act on trains people to ignore the ones
 *    they can.
 *
 * 2. Alerts are on symptoms the user feels, plus the specific internal signals that
 *    are silent failures. Queue depth and DLQ arrivals are the second kind: nothing
 *    is erroring, the API is fast, and payroll simply never completes.
 */

locals {
  # PagerDuty for anything that needs a human now; Slack for everything else.
  page_channels = compact([
    try(google_monitoring_notification_channel.pagerduty[0].id, null),
  ])

  slack_channels = compact([
    try(google_monitoring_notification_channel.slack[0].id, null),
  ])

  ticket_channels = compact([
    try(google_monitoring_notification_channel.email[0].id, null),
  ])

  all_channels = concat(local.page_channels, local.slack_channels)
}

# ---------------------------------------------------------------------------
# Notification channels
# ---------------------------------------------------------------------------

resource "google_monitoring_notification_channel" "pagerduty" {
  count = var.pagerduty_service_key == null ? 0 : 1

  project      = var.project_id
  display_name = "PagerDuty - ${var.name_prefix}"
  type         = "pagerduty"

  sensitive_labels {
    service_key = var.pagerduty_service_key
  }
}

resource "google_monitoring_notification_channel" "slack" {
  count = var.slack_webhook_url == null ? 0 : 1

  project      = var.project_id
  display_name = "Slack ${var.slack_channel}"
  type         = "webhook_tokenauth"

  labels = {
    url = var.slack_webhook_url
  }

  # Cloud Monitoring's native Slack channel needs an OAuth install; a webhook works
  # without one and is enough for alert text.
  description = "Incoming webhook to ${var.slack_channel}"
}

resource "google_monitoring_notification_channel" "email" {
  count = var.ops_email == null ? 0 : 1

  project      = var.project_id
  display_name = "Ops email"
  type         = "email"

  labels = {
    email_address = var.ops_email
  }
}

# ---------------------------------------------------------------------------
# Log-based metrics
#
# These turn application log lines into numbers. Both are things the platform
# already logs deliberately and nothing else would surface.
# ---------------------------------------------------------------------------

/**
 * A session presented to the wrong tenant. Should be exactly zero, forever.
 *
 * Non-zero means either an attack or a regression in the tenancy controls, and both
 * warrant waking somebody. This is the metric that makes the EnsureSessionTenant
 * middleware observable rather than just present.
 */
resource "google_logging_metric" "tenant_mismatch" {
  name    = "${var.name_prefix}/security/session_tenant_mismatch"
  project = var.project_id

  filter = <<-EOT
    resource.type="k8s_container"
    resource.labels.namespace_name="${var.app_namespace}"
    jsonPayload.message=~"Session/tenant mismatch"
  EOT

  description = "Sessions rejected because they belonged to a different tenant"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

/**
 * A failed audit write.
 *
 * The AuditLogger deliberately swallows its own failures so an audit problem cannot
 * fail a user's payroll submission. That is the right call for availability and the
 * wrong one for compliance unless something watches for it - a silently missing
 * audit trail is worse than a failed request.
 */
resource "google_logging_metric" "audit_write_failed" {
  name    = "${var.name_prefix}/compliance/audit_write_failed"
  project = var.project_id

  filter = <<-EOT
    resource.type="k8s_container"
    resource.labels.namespace_name="${var.app_namespace}"
    jsonPayload.message="AUDIT WRITE FAILED"
  EOT

  description = "Audit log writes that failed; the trail is incomplete while non-zero"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "authorization_denied" {
  name    = "${var.name_prefix}/security/authorization_denied"
  project = var.project_id

  filter = <<-EOT
    resource.type="k8s_container"
    resource.labels.namespace_name="${var.app_namespace}"
    jsonPayload.message="Authorization denied."
  EOT

  description = "Requests refused by the role check; a spike suggests a compromised account or broken client"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "role"
      value_type  = "STRING"
      description = "Role of the denied actor"
    }
  }

  label_extractors = {
    "role" = "EXTRACT(jsonPayload.role)"
  }
}

# ---------------------------------------------------------------------------
# PAGE: things that need a human now
# ---------------------------------------------------------------------------

/**
 * Poison messages arriving in the dead-letter queue.
 *
 * This is the silent failure this architecture is most prone to. Nothing errors at
 * the edge, the API returns 202 as always, and a tenant's payroll simply never
 * appears. Anything above zero means work has been abandoned.
 */
resource "google_monitoring_alert_policy" "dlq_messages" {
  count = length(local.page_channels) == 0 ? 0 : 1

  project      = var.project_id
  display_name = "[PAGE] Dead-letter queue is not empty"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      Messages have been dead-lettered after ${var.max_delivery_attempts} failed
      attempts. Work has been ABANDONED - a tenant's payroll run or sales import will
      never complete, and nobody has been told.

      Triage:
        1. Pull one without acking it:
           gcloud pubsub subscriptions pull ${var.dead_letter_subscription} --limit=5
        2. Read tenant_id, request_id and event_type from the envelope.
        3. Find the worker's reason:
           severity>=ERROR jsonPayload.request_id="<request_id>"
        4. Permanent failure (bad payload, unknown tenant)? Fix the cause, then have
           the tenant resubmit - the Idempotency-Key means a resubmit is safe.
        5. Transient failure that exhausted its retries? Republish to the original
           topic after the dependency is healthy.

      Runbook: ${var.runbook_base_url}/dlq-not-empty
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Undelivered messages in the dead-letter subscription"

    condition_threshold {
      filter = <<-EOT
        resource.type = "pubsub_subscription"
        AND resource.labels.subscription_id = "${var.dead_letter_subscription}"
        AND metric.type = "pubsub.googleapis.com/subscription/num_undelivered_messages"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = local.page_channels
  severity              = "CRITICAL"

  alert_strategy {
    auto_close = "86400s"
  }
}

/**
 * Queue backlog that the HPA is not clearing.
 *
 * Oldest-message age rather than message count: a big backlog draining quickly is
 * fine, while a small backlog that is not moving means the worker pool is wedged. The
 * threshold is generous enough that ordinary bursts do not page.
 */
resource "google_monitoring_alert_policy" "queue_not_draining" {
  count = length(local.page_channels) == 0 ? 0 : 1

  project      = var.project_id
  display_name = "[PAGE] Work queue is not draining"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      The oldest unacknowledged message has been waiting more than
      ${var.queue_age_threshold_minutes} minutes. Payroll runs and sales imports are
      accepted but not being processed, and callers see requests stuck in QUEUED.

      Triage:
        1. Are there any workers?  kubectl get pods -n ${var.app_namespace} -l app=worker
        2. Is the HPA scaling?     kubectl describe hpa worker -n ${var.app_namespace}
           (an HPA stuck at minReplicas usually means the custom metrics adapter is
           down, so it cannot see the backlog at all)
        3. Worker errors?          severity>=ERROR resource.labels.container_name="worker"
        4. Cloud SQL reachable?    check worker /readyz and the Cloud SQL dashboard
        5. Pool thrashing?         worker_tenant_pool_evictions_total climbing fast
           means DB_MAX_OPEN_SCHEMAS is too low and every message pays a reconnect

      Runbook: ${var.runbook_base_url}/queue-not-draining
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Oldest unacked message age"

    condition_threshold {
      filter = <<-EOT
        resource.type = "pubsub_subscription"
        AND resource.labels.subscription_id = one_of(${join(", ", [for s in var.worker_subscriptions : "\"${s}\""])})
        AND metric.type = "pubsub.googleapis.com/subscription/oldest_unacked_message_age"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = var.queue_age_threshold_minutes * 60
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = local.page_channels
  severity              = "CRITICAL"
}

/**
 * A session presented to the wrong tenant. Should never be non-zero.
 */
resource "google_monitoring_alert_policy" "tenant_isolation" {
  count = length(local.page_channels) == 0 ? 0 : 1

  project      = var.project_id
  display_name = "[PAGE] Cross-tenant session attempt"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      A session belonging to one tenant was presented to another tenant's hostname.
      EnsureSessionTenant rejected it, so no data crossed - but this should be
      impossible in normal operation.

      Two explanations, both urgent:
        - An attack: someone is deliberately replaying a session across tenants.
        - A regression: SESSION_DOMAIN was widened, or the per-tenant cookie name was
          changed, and the implicit cookie-scoping protection is gone.

      Triage:
        1. jsonPayload.message=~"Session/tenant mismatch" - read session_tenant,
           request_tenant and ip.
        2. Confirm SESSION_DOMAIN is unset and TENANCY_TRUST_HEADER is false:
           kubectl get cm app-config -n ${var.app_namespace} -o yaml
        3. If it is one IP, block it at Cloud Armor. If it is many, treat as a
           security incident.

      Runbook: ${var.runbook_base_url}/cross-tenant-session
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Any cross-tenant session rejection"

    condition_threshold {
      filter = <<-EOT
        resource.type = "k8s_container"
        AND metric.type = "logging.googleapis.com/user/${google_logging_metric.tenant_mismatch.name}"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = local.page_channels
  severity              = "CRITICAL"
}

resource "google_monitoring_alert_policy" "api_error_rate" {
  count = length(local.page_channels) == 0 ? 0 : 1

  project      = var.project_id
  display_name = "[PAGE] API 5xx rate above SLO"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      The load balancer is returning 5xx above ${var.error_rate_threshold * 100}% of
      requests. Users are seeing failures.

      Triage:
        1. Pods ready?  kubectl get pods -n ${var.app_namespace} -l app=web-api
        2. Backends healthy in the LB, or all failing health checks?
        3. Recent rollout? Argo Rollouts should have aborted on its own analysis -
           check: kubectl argo rollouts get rollout web-api -n ${var.app_namespace}
        4. Dependency down? /readyz reports mysql, redis and firestore individually.

      Runbook: ${var.runbook_base_url}/api-error-rate
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "5xx ratio over 5 minutes"

    condition_threshold {
      filter = <<-EOT
        resource.type = "https_lb_rule"
        AND metric.type = "loadbalancing.googleapis.com/https/request_count"
        AND metric.labels.response_code_class = "500"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = var.error_rate_requests_per_second
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = local.page_channels
  severity              = "CRITICAL"
}

resource "google_monitoring_alert_policy" "cloudsql_down" {
  count = length(local.page_channels) == 0 ? 0 : 1

  project      = var.project_id
  display_name = "[PAGE] Cloud SQL unavailable"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      The Cloud SQL instance is not reporting as up. Every read fails and the worker
      nacks everything it leases (so nothing is lost, but nothing progresses).

      Triage:
        1. gcloud sql instances describe ${var.sql_instance}
        2. Regional HA should fail over automatically within ~60s; if it has not,
           check the operations log for a stuck maintenance or failover.
        3. Once healthy, the Pub/Sub backlog drains on its own - do not replay
           messages by hand.

      Runbook: ${var.runbook_base_url}/cloudsql-down
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Instance up = 0"

    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database"
        AND resource.labels.database_id = "${var.project_id}:${var.sql_instance}"
        AND metric.type = "cloudsql.googleapis.com/database/up"
      EOT

      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "120s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MIN"
      }
    }
  }

  notification_channels = local.page_channels
  severity              = "CRITICAL"
}

# ---------------------------------------------------------------------------
# SLACK: worth knowing about, not worth waking anyone
# ---------------------------------------------------------------------------

/**
 * Connection saturation.
 *
 * Warns before exhaustion rather than after, because the failure mode is bad: once
 * connections run out, EVERY tenant fails at once, including the ones behaving
 * perfectly. The worker's per-tenant pools mean usage grows with pods x tenants, so
 * this creeps up as the platform grows rather than spiking.
 */
resource "google_monitoring_alert_policy" "cloudsql_connections" {
  count = length(local.slack_channels) == 0 ? 0 : 1

  project      = var.project_id
  display_name = "[WARN] Cloud SQL connections above ${var.connection_warn_percent}%"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      Connection usage is climbing toward the instance limit. When it is reached,
      every tenant fails simultaneously.

      Connections scale with pods x tenants:
        worker: replicas x DB_MAX_OPEN_SCHEMAS x DB_MAX_OPEN_CONNS
        web:    replicas x php-fpm pm.max_children

      Options, cheapest first:
        1. Lower DB_MAX_OPEN_SCHEMAS on the worker (costs reconnects, not capacity) -
           watch worker_tenant_pool_evictions_total afterwards.
        2. Lower DB_MAX_OPEN_CONNS.
        3. Raise max_connections and the instance tier (Terraform).

      Runbook: ${var.runbook_base_url}/cloudsql-connections
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Connection utilisation"

    condition_threshold {
      filter = <<-EOT
        resource.type = "cloudsql_database"
        AND resource.labels.database_id = "${var.project_id}:${var.sql_instance}"
        AND metric.type = "cloudsql.googleapis.com/database/mysql/connections"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = var.max_connections * (var.connection_warn_percent / 100)
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = local.slack_channels
  severity              = "WARNING"
}

resource "google_monitoring_alert_policy" "audit_write_failed" {
  count = length(local.slack_channels) == 0 ? 0 : 1

  project      = var.project_id
  display_name = "[WARN] Audit writes are failing"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      Audit log writes are failing. Requests still succeed - the AuditLogger swallows
      its own errors so a compliance problem cannot become an availability one - which
      means the ONLY signal that the trail is incomplete is this alert.

      Triage:
        1. jsonPayload.message="AUDIT WRITE FAILED" - the error field says why.
        2. Usually a schema drift (a migration did not run against every tenant) or
           Cloud SQL rejecting writes.
        3. Confirm every tenant is migrated: kubectl logs job/tenants-migrate
        4. Note the window in the incident record: those actions are unattributable
           and an auditor will ask about the gap.

      Runbook: ${var.runbook_base_url}/audit-write-failed
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Any failed audit write"

    condition_threshold {
      filter = <<-EOT
        resource.type = "k8s_container"
        AND metric.type = "logging.googleapis.com/user/${google_logging_metric.audit_write_failed.name}"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = local.slack_channels
  severity              = "WARNING"
}

resource "google_monitoring_alert_policy" "worker_permanent_failures" {
  count = length(local.slack_channels) == 0 ? 0 : 1

  project      = var.project_id
  display_name = "[WARN] Worker permanent failures"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      The worker is marking requests FAILED without retrying: a bad payload, an
      unknown tenant, or a referential integrity violation. Retrying cannot fix these,
      so the worker acks them - callers see FAILED with a reason.

      A steady trickle usually means a client is sending something the API accepts but
      the worker rejects, which is a validation gap worth closing.

      Query: worker_messages_permanent_failed_total, then
        severity>=ERROR jsonPayload.message="permanent failure, acking"

      Runbook: ${var.runbook_base_url}/worker-permanent-failures
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Permanent failure rate"

    condition_threshold {
      filter = <<-EOT
        resource.type = "prometheus_target"
        AND metric.type = "prometheus.googleapis.com/worker_messages_permanent_failed_total/counter"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = var.permanent_failure_threshold
      duration        = "600s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = local.slack_channels
  severity              = "WARNING"
}

resource "google_monitoring_alert_policy" "redis_memory" {
  count = length(local.slack_channels) == 0 ? 0 : 1

  project      = var.project_id
  display_name = "[WARN] Memorystore memory above ${var.redis_warn_percent}%"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      Memorystore is filling up. The eviction policy is allkeys-lru, so it will start
      evicting rather than refusing writes - but the things it evicts matter:

        - sessions -> users are signed out mid-task
        - idempotency claims -> a client's retry looks like a new operation, which is
          exactly the duplicate-payroll-run failure the claims exist to prevent

      Raise memory_size_gb, or move sessions to their own instance so cache pressure
      cannot evict them.

      Runbook: ${var.runbook_base_url}/redis-memory
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Memory utilisation ratio"

    condition_threshold {
      filter = <<-EOT
        resource.type = "redis_instance"
        AND metric.type = "redis.googleapis.com/stats/memory/usage_ratio"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = var.redis_warn_percent / 100
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = local.slack_channels
  severity              = "WARNING"
}

resource "google_monitoring_alert_policy" "certificate_expiry" {
  count = length(local.slack_channels) == 0 ? 0 : 1

  project      = var.project_id
  display_name = "[WARN] SSL certificate expiring"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      A managed certificate is close to expiry. Renewal is automatic, so this firing
      means renewal is FAILING - usually because a tenant's DNS no longer resolves to
      the load balancer, or the DNS authorisation CNAME for the wildcard was removed.

      Check: gcloud certificate-manager certificates describe ${var.name_prefix}-wildcard

      Runbook: ${var.runbook_base_url}/certificate-expiry
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Days until expiry"

    condition_threshold {
      filter = <<-EOT
        resource.type = "gce_instance"
        AND metric.type = "loadbalancing.googleapis.com/https/ssl_certificate/expiration_days_remaining"
      EOT

      comparison      = "COMPARISON_LT"
      threshold_value = 21
      duration        = "3600s"

      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_MIN"
      }
    }
  }

  notification_channels = local.slack_channels
  severity              = "WARNING"
}

# ---------------------------------------------------------------------------
# Uptime check: does the platform answer from outside GCP at all
# ---------------------------------------------------------------------------

resource "google_monitoring_uptime_check_config" "api" {
  count = var.uptime_check_host == null ? 0 : 1

  project      = var.project_id
  display_name = "${var.name_prefix} API health"
  timeout      = "10s"
  period       = "60s"

  http_check {
    # /healthz needs no tenant and no auth, and touches no dependency - so this
    # measures reachability, not the health of Cloud SQL.
    path         = "/healthz"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"

    labels = {
      project_id = var.project_id
      host       = var.uptime_check_host
    }
  }

  # Multiple regions so one probe location having a bad day is not an outage.
  selected_regions = ["USA", "EUROPE", "ASIA_PACIFIC"]
}

resource "google_monitoring_alert_policy" "uptime" {
  count = var.uptime_check_host == null || length(local.page_channels) == 0 ? 0 : 1

  project      = var.project_id
  display_name = "[PAGE] API unreachable from the internet"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      The uptime check is failing from multiple regions: the platform is unreachable
      from outside GCP.

      Triage, edge inward:
        1. DNS still resolving to the load balancer IP?
        2. Certificate ACTIVE, not PROVISIONING or FAILED?
        3. Backend service has healthy backends? Empty NEGs are the classic cause -
           see the note in terraform/modules/edge about the NEG ordering.
        4. Any pods at all?  kubectl get pods -n ${var.app_namespace}

      Runbook: ${var.runbook_base_url}/api-unreachable
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Uptime check failing"

    condition_threshold {
      filter = <<-EOT
        resource.type = "uptime_url"
        AND metric.type = "monitoring.googleapis.com/uptime_check/check_passed"
        AND metric.labels.check_id = "${google_monitoring_uptime_check_config.api[0].uptime_check_id}"
      EOT

      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "180s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }

      trigger {
        count = 2
      }
    }
  }

  notification_channels = local.page_channels
  severity              = "CRITICAL"
}

# ---------------------------------------------------------------------------
# SLOs
#
# Defined so burn-rate alerting has something to measure against, and so "is the
# platform healthy" has a number rather than an opinion.
# ---------------------------------------------------------------------------

resource "google_monitoring_custom_service" "api" {
  count = var.create_slos ? 1 : 0

  project      = var.project_id
  service_id   = "${var.name_prefix}-api"
  display_name = "Sequifi API"
}

resource "google_monitoring_slo" "availability" {
  count = var.create_slos ? 1 : 0

  project      = var.project_id
  service      = google_monitoring_custom_service.api[0].service_id
  slo_id       = "availability"
  display_name = "API availability ${var.availability_slo * 100}%"

  goal                = var.availability_slo
  rolling_period_days = 30

  request_based_sli {
    good_total_ratio {
      good_service_filter = <<-EOT
        metric.type="loadbalancing.googleapis.com/https/request_count"
        resource.type="https_lb_rule"
        metric.label.response_code_class!="500"
      EOT

      total_service_filter = <<-EOT
        metric.type="loadbalancing.googleapis.com/https/request_count"
        resource.type="https_lb_rule"
      EOT
    }
  }
}

resource "google_monitoring_slo" "latency" {
  count = var.create_slos ? 1 : 0

  project      = var.project_id
  service      = google_monitoring_custom_service.api[0].service_id
  slo_id       = "latency"
  display_name = "API latency: ${var.latency_slo * 100}% under ${var.latency_threshold_ms}ms"

  goal                = var.latency_slo
  rolling_period_days = 30

  request_based_sli {
    distribution_cut {
      distribution_filter = <<-EOT
        metric.type="loadbalancing.googleapis.com/https/total_latencies"
        resource.type="https_lb_rule"
      EOT

      range {
        max = var.latency_threshold_ms
      }
    }
  }
}

/**
 * Multi-window burn-rate alert.
 *
 * Fires when the error budget is being consumed fast enough to exhaust it well
 * before the window ends, rather than when a fixed error rate is crossed. That is
 * the difference between "we will breach the SLO" and "we breached it an hour ago".
 */
resource "google_monitoring_alert_policy" "slo_burn" {
  count = var.create_slos && length(local.page_channels) > 0 ? 1 : 0

  project      = var.project_id
  display_name = "[PAGE] Error budget burning fast"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      The availability error budget is being consumed at ${var.burn_rate_threshold}x
      the sustainable rate. At this pace the 30 day budget is gone long before the
      window closes.

      This is a leading indicator, not a fixed error-rate alert: it fires while there
      is still budget left to protect.

      Triage: same as [PAGE] API 5xx rate above SLO.
      Runbook: ${var.runbook_base_url}/slo-burn-rate
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Fast burn (1h window)"

    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.availability[0].name}\", \"3600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = var.burn_rate_threshold
      duration        = "300s"
    }
  }

  conditions {
    display_name = "Slow burn (6h window)"

    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.availability[0].name}\", \"21600s\")"
      comparison      = "COMPARISON_GT"
      threshold_value = var.burn_rate_threshold / 3
      duration        = "1800s"
    }
  }

  notification_channels = local.page_channels
  severity              = "CRITICAL"
}
