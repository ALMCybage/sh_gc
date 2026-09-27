variable "project_id" { type = string }
variable "name_prefix" { type = string }

variable "app_namespace" {
  type        = string
  description = "Kubernetes namespace the application runs in."
  default     = "sequifi"
}

variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

variable "web_api_secret_ids" {
  type        = list(string)
  description = "Secret Manager ids the web tier may read."
  default     = []
}

variable "worker_secret_ids" {
  type        = list(string)
  description = "Secret Manager ids the worker may read."
  default     = []
}

variable "github_repository" {
  type        = string
  description = <<-EOT
    "owner/repo" for GitHub Actions OIDC federation. Null disables CI identity
    entirely. The value is used in the provider's attribute_condition, which is what
    stops any other repository from minting credentials for this project.
  EOT
  default     = null
}
