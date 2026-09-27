output "web_api_service_account" {
  value       = google_service_account.web_api.email
  description = "Annotate the web-api KSA with this."
}

output "worker_service_account" {
  value = google_service_account.worker.email
}

output "metrics_adapter_service_account" {
  value = google_service_account.metrics_adapter.email
}

output "argocd_service_account" {
  value = google_service_account.argocd.email
}

output "ci_deployer_service_account" {
  value       = try(google_service_account.ci_deployer[0].email, null)
  description = "Set as GCP_SERVICE_ACCOUNT in GitHub Actions."
}

output "github_workload_identity_provider" {
  value       = try(google_iam_workload_identity_pool_provider.github[0].name, null)
  description = "Set as GCP_WORKLOAD_IDENTITY_PROVIDER in GitHub Actions."
}
