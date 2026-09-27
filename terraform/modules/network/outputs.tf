output "network_id" {
  value       = google_compute_network.vpc.id
  description = "Self link of the VPC."
}

output "network_name" {
  value       = google_compute_network.vpc.name
  description = "VPC name, for resources that take a name rather than a self link."
}

output "subnet_id" {
  value       = google_compute_subnetwork.primary.id
  description = "Self link of the primary subnet."
}

output "subnet_name" {
  value       = google_compute_subnetwork.primary.name
  description = "Primary subnet name."
}

output "pods_range_name" {
  value       = "pods"
  description = "Secondary range name for GKE pods."
}

output "services_range_name" {
  value       = "services"
  description = "Secondary range name for GKE services."
}

output "private_service_connection" {
  value       = google_service_networking_connection.private_services.id
  description = <<-EOT
    Exported so Cloud SQL and Memorystore can depend_on it. Creating a private-IP
    instance before the peering exists fails with an unhelpful error.
  EOT
}
