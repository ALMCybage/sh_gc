output "cluster_name" {
  value = module.gke.cluster_name
}

output "get_credentials_command" {
  value       = module.gke.get_credentials_command
  description = "Run this before anything in bootstrap/."
}

output "load_balancer_ip" {
  value       = module.edge.load_balancer_ip
  description = "Point every tenant's DNS A record here."
}

output "url_map_name" {
  value = module.edge.url_map_name
}

output "dns_records_required" {
  value = concat(
    [for id, cfg in var.tenants : {
      name = "${id}.${var.base_domain}"
      type = "A"
      data = module.edge.load_balancer_ip
    }],
    module.edge.dns_authorization_record == null ? [] : [module.edge.dns_authorization_record]
  )
  description = <<-EOT
    Everything that must exist in DNS. The certificate stays in PROVISIONING until
    these resolve, and an unprovisioned certificate means TLS errors for every tenant.
  EOT
}

output "sql_connection_name" {
  value       = module.cloudsql.connection_name
  description = "The argument for the cloud-sql-proxy sidecar."
}

output "redis_host" {
  value = module.data.redis_host
}

output "artifact_registry_url" {
  value = module.data.artifact_registry_url
}

output "frontend_bucket" {
  value = module.data.frontend_bucket
}

output "topics" {
  value = module.data.topics
}

output "subscriptions" {
  value = module.data.subscriptions
}

output "dead_letter_subscription" {
  value = module.data.dead_letter_subscription
}

output "service_accounts" {
  value = {
    web_api         = module.iam.web_api_service_account
    worker          = module.iam.worker_service_account
    metrics_adapter = module.iam.metrics_adapter_service_account
    argocd          = module.iam.argocd_service_account
    ci_deployer     = module.iam.ci_deployer_service_account
  }
  description = "Annotate the matching Kubernetes service accounts with these."
}

output "github_workload_identity_provider" {
  value       = module.iam.github_workload_identity_provider
  description = "Set as the GCP_WORKLOAD_IDENTITY_PROVIDER secret in GitHub."
}

output "secret_ids" {
  value = {
    app_key     = google_secret_manager_secret.app_key.secret_id
    db_password = module.cloudsql.db_password_secret_id
    redis_auth  = module.data.redis_auth_secret_id
  }
  description = <<-EOT
    Secret Manager ids. The values are deliberately not outputs: Terraform outputs are
    stored in state, and state is far more widely readable than a secret with its own
    IAM policy.
  EOT
}

output "tenants_json" {
  value       = local.tenants_json
  description = "The registry both services read. Written into the app ConfigMap by bootstrap."
}

output "paging_enabled" {
  value       = module.monitoring.paging_enabled
  description = "False means no [PAGE] alert exists. Expected in dev; verify before calling prod ready."
}

output "next_steps" {
  value = <<-EOT
    1. ${module.gke.get_credentials_command}
    2. Create the DNS records in `dns_records_required`.
    3. ./bootstrap/run-all.sh          (addons, ArgoCD, secrets, first sync)
    4. Collect the NEGs and re-apply so the LB has backends:
         gcloud compute network-endpoint-groups list --filter="name=web-api-neg" \
           --format="value(selfLink)"
       then set api_neg_self_links in this environment's tfvars and apply again.
    5. Wait for the certificate to become ACTIVE (15-60 minutes after DNS resolves).
  EOT
}
