output "notification_channels" {
  value = {
    pagerduty = try(google_monitoring_notification_channel.pagerduty[0].id, null)
    slack     = try(google_monitoring_notification_channel.slack[0].id, null)
    email     = try(google_monitoring_notification_channel.email[0].id, null)
  }
  description = "Channel ids, reusable by Alertmanager or additional policies."
}

output "log_metrics" {
  value = {
    tenant_mismatch      = google_logging_metric.tenant_mismatch.name
    audit_write_failed   = google_logging_metric.audit_write_failed.name
    authorization_denied = google_logging_metric.authorization_denied.name
  }
}

output "slo_names" {
  value = {
    availability = try(google_monitoring_slo.availability[0].name, null)
    latency      = try(google_monitoring_slo.latency[0].name, null)
  }
}

output "paging_enabled" {
  value       = var.pagerduty_service_key != null
  description = "False means no [PAGE] policy was created. Expected in dev, a mistake in prod."
}
