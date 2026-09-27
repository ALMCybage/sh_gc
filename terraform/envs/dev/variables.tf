variable "project_id" { type = string }

variable "region" {
  type    = string
  default = "us-central1"
}

variable "base_domain" {
  type    = string
  default = "dev.sequifi.com"
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "slack_webhook_url" {
  type      = string
  default   = null
  sensitive = true
}

variable "github_repository" {
  type    = string
  default = null
}

variable "api_neg_self_links" {
  type        = list(string)
  description = "Populated after the first workload deploy; see bootstrap/README.md."
  default     = []
}
