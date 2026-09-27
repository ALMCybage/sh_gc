variable "project_id" { type = string }
variable "region" { type = string }
variable "name_prefix" { type = string }
variable "network_id" { type = string }

variable "private_service_connection" {
  type        = any
  description = "VPC peering connection; Memorystore with PRIVATE_SERVICE_ACCESS depends on it."
}

variable "api_dependencies" {
  type    = any
  default = null
}

# --- Memorystore -----------------------------------------------------------

variable "redis_tier" {
  type        = string
  description = "STANDARD_HA gives a replica and automatic failover. Sessions live here."
  default     = "STANDARD_HA"
}

variable "redis_memory_gb" {
  type    = number
  default = 5
}

variable "redis_version" {
  type    = string
  default = "REDIS_7_0"
}

# --- Firestore -------------------------------------------------------------

variable "firestore_location" {
  type        = string
  description = "Firestore location id. Cannot be changed after creation."
  default     = "us-central1"
}

variable "firestore_collection" {
  type    = string
  default = "api_request_statuses"
}

variable "firestore_delete_protection" {
  type    = bool
  default = true
}

# --- Pub/Sub ---------------------------------------------------------------

variable "topics" {
  type = map(object({
    topic        = string
    subscription = string
  }))
  description = "flow name => topic and worker subscription names."
  default = {
    payroll = {
      topic        = "payroll-calc-events"
      subscription = "payroll-calc-events-worker"
    }
    sales = {
      topic        = "sales-import"
      subscription = "sales-import-worker"
    }
  }
}

variable "dlq_topic" {
  type    = string
  default = "worker-dead-letter"
}

variable "max_delivery_attempts" {
  type        = number
  description = "Keep in step with the worker's WORKER_MAX_RETRIES."
  default     = 5

  validation {
    condition     = var.max_delivery_attempts >= 5 && var.max_delivery_attempts <= 100
    error_message = "Pub/Sub requires max_delivery_attempts between 5 and 100."
  }
}

# --- Artifact Registry -----------------------------------------------------

variable "artifact_repository" {
  type    = string
  default = "sequifi"
}

# --- Frontend bucket -------------------------------------------------------

variable "frontend_bucket" {
  type        = string
  description = "Globally unique bucket name for the built SPA."
}

variable "frontend_bucket_force_destroy" {
  type        = bool
  description = "Allows terraform destroy to empty the bucket. True in dev only."
  default     = false
}

variable "frontend_cors_origins" {
  type        = list(string)
  description = "Only needed if the SPA is ever served from a different origin than the API."
  default     = []
}

variable "labels" {
  type    = map(string)
  default = {}
}
