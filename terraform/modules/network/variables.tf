variable "project_id" {
  type        = string
  description = "GCP project id."
}

variable "region" {
  type        = string
  description = "Region for the subnet, router and NAT."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for every resource name, e.g. sequifi-prod."
}

variable "subnet_cidr" {
  type        = string
  description = "Primary node range."
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  type        = string
  description = <<-EOT
    Secondary range for pods. Size it for the maximum pod count you ever expect:
    a /16 gives ~65k pod IPs, and it cannot be grown without recreating the cluster.
  EOT
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  type        = string
  description = "Secondary range for ClusterIP services."
  default     = "10.30.0.0/20"
}
