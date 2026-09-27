variable "project_id" { type = string }
variable "name_prefix" { type = string }

variable "base_domain" {
  type        = string
  description = "e.g. sequifi.com. Tenants are subdomains of this."
}

variable "domains" {
  type        = list(string)
  description = "Hostnames the URL map answers on, and the certificate SANs when not using a wildcard."
}

variable "use_wildcard_certificate" {
  type        = bool
  description = <<-EOT
    True uses Certificate Manager with *.base_domain, which is required past ~100
    tenants and makes onboarding a DNS record only. False uses a classic managed
    certificate with an explicit domain list - simpler, but capped at 100 domains and
    every new tenant is a certificate change.
  EOT
  default     = false
}

variable "frontend_bucket" {
  type        = string
  description = "GCS bucket holding the built SPA."
}

variable "api_neg_self_links" {
  type        = list(string)
  description = <<-EOT
    Self links of the zonal NEGs created by the Kubernetes Service annotation.

    Empty on the first apply, because the NEGs do not exist until the workload is
    deployed. The bootstrap sequence applies infrastructure, deploys, then re-applies
    with these populated. Discover them with:

      gcloud compute network-endpoint-groups list --filter="name=web-api-neg" \
        --format="value(selfLink)"
  EOT
  default     = []
}

variable "api_container_port" {
  type        = number
  description = "Port nginx listens on inside the pod."
  default     = 8080
}

variable "backend_timeout_sec" {
  type        = number
  description = "Must exceed the application's own request timeout."
  default     = 40
}

variable "connection_draining_sec" {
  type        = number
  description = "Must be below the pods' terminationGracePeriodSeconds, or rollouts drop connections."
  default     = 45
}

variable "max_rate_per_endpoint" {
  type        = number
  description = "Requests per second per pod before the LB spreads load elsewhere."
  default     = 100
}

variable "rate_limit_per_minute" {
  type        = number
  description = "Cloud Armor per-IP threshold before a 5 minute ban."
  default     = 1000
}

variable "waf_preview_only" {
  type        = bool
  description = <<-EOT
    True logs WAF matches without blocking. Deploy in preview first: turning OWASP
    rules straight to deny on a JSON API is how legitimate payroll submissions get
    blocked on day one.
  EOT
  default     = true
}

variable "waf_rules" {
  type = list(object({
    priority    = number
    rule_set    = string
    sensitivity = number
    description = string
  }))
  default = [
    { priority = 2000, rule_set = "sqli-v33-stable", sensitivity = 1, description = "SQL injection" },
    { priority = 2001, rule_set = "xss-v33-stable", sensitivity = 1, description = "Cross-site scripting" },
    { priority = 2002, rule_set = "lfi-v33-stable", sensitivity = 1, description = "Local file inclusion" },
    { priority = 2003, rule_set = "rce-v33-stable", sensitivity = 1, description = "Remote code execution" },
    { priority = 2004, rule_set = "scannerdetection-v33-stable", sensitivity = 1, description = "Scanner detection" },
  ]
}

variable "lb_log_sample_rate" {
  type    = number
  default = 0.1
}
