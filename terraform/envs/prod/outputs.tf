output "stack" {
  value = {
    cluster_name          = module.stack.cluster_name
    get_credentials       = module.stack.get_credentials_command
    load_balancer_ip      = module.stack.load_balancer_ip
    url_map_name          = module.stack.url_map_name
    artifact_registry_url = module.stack.artifact_registry_url
    frontend_bucket       = module.stack.frontend_bucket
    sql_connection_name   = module.stack.sql_connection_name
    redis_host            = module.stack.redis_host
    service_accounts      = module.stack.service_accounts
    secret_ids            = module.stack.secret_ids
    subscriptions         = module.stack.subscriptions
    dead_letter           = module.stack.dead_letter_subscription
    paging_enabled        = module.stack.paging_enabled
  }
}

output "dns_records_required" {
  value = module.stack.dns_records_required
}

output "tenants_json" {
  value = module.stack.tenants_json
}

output "github_workload_identity_provider" {
  value = module.stack.github_workload_identity_provider
}

output "next_steps" {
  value = module.stack.next_steps
}
