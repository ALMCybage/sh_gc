output "instance_name" {
  value = google_sql_database_instance.primary.name
}

output "connection_name" {
  value       = google_sql_database_instance.primary.connection_name
  description = "PROJECT:REGION:INSTANCE, the argument the Cloud SQL Auth Proxy sidecar takes."
}

output "private_ip" {
  value       = google_sql_database_instance.primary.private_ip_address
  description = "Informational. The application never uses this; it talks to the proxy on localhost."
}

output "replica_connection_name" {
  value       = try(google_sql_database_instance.replica[0].connection_name, null)
  description = "Read replica, for reporting workloads."
}

output "app_username" {
  value = google_sql_user.app.name
}

output "db_password_secret_id" {
  value       = google_secret_manager_secret.db_password.secret_id
  description = <<-EOT
    Secret Manager id holding the app user's password. The password itself is
    deliberately not an output: outputs land in the Terraform state file, and state
    is far more widely readable than a secret with its own IAM policy.
  EOT
}

output "db_password_secret_name" {
  value = google_secret_manager_secret.db_password.name
}

output "tenant_schemas" {
  value = { for k, v in google_sql_database.tenant : k => v.name }
}
