output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_id" {
  value = google_container_cluster.primary.id
}

output "endpoint" {
  value       = google_container_cluster.primary.endpoint
  description = "Control plane address."
  sensitive   = true
}

output "ca_certificate" {
  value     = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "workload_identity_pool" {
  value       = "${var.project_id}.svc.id.goog"
  description = "Used when binding a Kubernetes service account to a Google one."
}

output "get_credentials_command" {
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --region ${var.region} --project ${var.project_id}"
  description = "Copy-paste to configure kubectl."
}
