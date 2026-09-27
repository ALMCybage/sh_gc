variable "project_id" { type = string }

variable "region" {
  type    = string
  default = "us-central1"
}

variable "base_domain" {
  type    = string
  default = "sequifi.com"
}

variable "tenants" {
  type = map(object({
    name   = string
    schema = string
  }))
  description = "The production tenant registry. Adding an entry provisions a schema and a hostname."

  default = {
    acme        = { name = "Acme Corp", schema = "tenant_acme" }
    whiteknight = { name = "White Knight", schema = "tenant_whiteknight" }
    frdm        = { name = "FRDM", schema = "tenant_frdm" }
  }
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  description = "Required. Office egress and CI runner ranges."

  validation {
    condition     = length(var.master_authorized_networks) > 0
    error_message = "Production requires at least one authorized network: an unrestricted Kubernetes API endpoint has only IAM in front of it."
  }

  validation {
    condition     = !contains([for n in var.master_authorized_networks : n.cidr_block], "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not an authorized network. Restrict to office egress and CI runner ranges."
  }
}

variable "pagerduty_service_key" {
  type        = string
  description = "Required in prod. No default, so an apply cannot silently ship without paging."
  sensitive   = true

  validation {
    condition     = length(var.pagerduty_service_key) > 10
    error_message = "pagerduty_service_key looks empty or truncated; the [PAGE] alert policies are not created without it."
  }
}

variable "slack_webhook_url" {
  type      = string
  default   = null
  sensitive = true
}

variable "ops_email" {
  type    = string
  default = null
}

variable "runbook_base_url" {
  type    = string
  default = "https://github.com/your-org/sequifi/blob/main/docs/runbook"
}

variable "usage_export_dataset" {
  type        = string
  description = "BigQuery dataset for per-namespace cost attribution."
  default     = null
}

variable "github_repository" {
  type    = string
  default = null
}

variable "api_neg_self_links" {
  type    = list(string)
  default = []
}
