variable "project_id" { type = string }
variable "name_prefix" { type = string }

variable "app_namespace" {
  type    = string
  default = "sequifi"
}

# --- routing ---------------------------------------------------------------

variable "pagerduty_service_key" {
  type        = string
  description = <<-EOT
    PagerDuty Events API v2 integration key. Null disables every [PAGE] policy, which
    is the right setting for a dev environment - a dev cluster paging an on-call
    engineer is how alerting gets muted everywhere.
  EOT
  default     = null
  sensitive   = true
}

variable "slack_webhook_url" {
  type        = string
  description = "Incoming webhook for [WARN] policies. Null disables them."
  default     = null
  sensitive   = true
}

variable "slack_channel" {
  type    = string
  default = "#sequifi-alerts"
}

variable "ops_email" {
  type    = string
  default = null
}

variable "runbook_base_url" {
  type        = string
  description = "Every alert links to a runbook page. An alert without one is a puzzle, not a signal."
  default     = "https://github.com/your-org/sequifi/blob/main/docs/runbook"
}

# --- what to watch ---------------------------------------------------------

variable "sql_instance" { type = string }
variable "max_connections" { type = number }

variable "worker_subscriptions" {
  type        = list(string)
  description = "Subscription ids whose backlog age is alerted on."
}

variable "dead_letter_subscription" { type = string }

variable "max_delivery_attempts" {
  type    = number
  default = 5
}

variable "uptime_check_host" {
  type        = string
  description = "Hostname probed from outside GCP, e.g. acme.sequifi.com. Null disables the check."
  default     = null
}

# --- thresholds ------------------------------------------------------------

variable "queue_age_threshold_minutes" {
  type        = number
  description = "Oldest unacked message age that means the pool is not keeping up."
  default     = 15
}

variable "error_rate_threshold" {
  type        = number
  description = "Informational, used in the alert text."
  default     = 0.01
}

variable "error_rate_requests_per_second" {
  type        = number
  description = "5xx per second that trips the page. Tune to your traffic; too low and it cries wolf."
  default     = 1
}

variable "connection_warn_percent" {
  type    = number
  default = 75
}

variable "redis_warn_percent" {
  type    = number
  default = 80
}

variable "permanent_failure_threshold" {
  type        = number
  description = "Permanent failures per second before it is worth investigating."
  default     = 0.05
}

# --- SLOs ------------------------------------------------------------------

variable "create_slos" {
  type    = bool
  default = true
}

variable "availability_slo" {
  type        = number
  description = "0.999 = three nines over 30 days, about 43 minutes of budget."
  default     = 0.999
}

variable "latency_slo" {
  type    = number
  default = 0.99
}

variable "latency_threshold_ms" {
  type        = number
  description = "The async design means writes return in ~150ms, so 1s is generous for the 99th percentile."
  default     = 1000
}

variable "burn_rate_threshold" {
  type        = number
  description = "14.4x over 1h exhausts a 30 day budget in ~2 days: the standard fast-burn figure."
  default     = 14.4
}
