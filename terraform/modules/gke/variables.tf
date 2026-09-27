variable "project_id" { type = string }
variable "region" { type = string }
variable "cluster_name" { type = string }

variable "network_id" { type = string }
variable "subnet_id" { type = string }
variable "pods_range_name" { type = string }
variable "services_range_name" { type = string }

variable "master_cidr" {
  type        = string
  description = "Control plane range. Must not overlap any subnet or peered range."
  default     = "172.16.0.0/28"
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  description = <<-EOT
    Who may reach the Kubernetes API. Restrict this to your office egress and CI
    runners; leaving it open to 0.0.0.0/0 means the control plane is reachable from
    anywhere with only IAM in front of it.
  EOT
  default     = []
}

variable "release_channel" {
  type    = string
  default = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "deletion_protection" {
  type        = bool
  description = "Blocks `terraform destroy` from removing the cluster."
  default     = true
}

variable "database_encryption_key" {
  type        = string
  description = "Cloud KMS key for etcd Secret encryption. Null uses Google-managed keys."
  default     = null
}

variable "usage_export_dataset" {
  type        = string
  description = "BigQuery dataset id for per-namespace cost attribution. Null disables it."
  default     = null
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "api_dependencies" {
  type        = any
  description = "Anything the cluster must wait for, typically the enabled-APIs resource."
  default     = null
}
