output "load_balancer_ip" {
  value       = google_compute_global_address.lb.address
  description = "Point every tenant's DNS A record here."
}

output "url_map_name" {
  value       = google_compute_url_map.https.name
  description = "Needed to invalidate the CDN cache after a frontend deploy."
}

output "backend_service_name" {
  value = google_compute_backend_service.api.name
}

output "security_policy_name" {
  value = google_compute_security_policy.armor.name
}

output "dns_authorization_record" {
  value = try({
    name = google_certificate_manager_dns_authorization.wildcard[0].dns_resource_record[0].name
    type = google_certificate_manager_dns_authorization.wildcard[0].dns_resource_record[0].type
    data = google_certificate_manager_dns_authorization.wildcard[0].dns_resource_record[0].data
  }, null)
  description = <<-EOT
    CNAME that must exist before the wildcard certificate can be issued. The
    certificate sits in PROVISIONING until it resolves.
  EOT
}

output "attach_negs_command" {
  value       = <<-EOT
    After the first workload deploy, collect the NEGs and re-apply:

      gcloud compute network-endpoint-groups list \
        --filter="name=web-api-neg" --format="value(selfLink)"

    Put the results in api_neg_self_links and run terraform apply again.
  EOT
  description = "The one manual step in the ordering between Terraform and the cluster."
}
