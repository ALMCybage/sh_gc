variable "project_id" { type = string }
variable "region" { type = string }
variable "name_prefix" { type = string }
variable "instance_name" { type = string }
variable "network_id" { type = string }

variable "private_service_connection" {
  type        = any
  description = "The VPC peering connection; a private-IP instance cannot be created before it exists."
}

variable "database_version" {
  type    = string
  default = "MYSQL_8_0"
}

variable "edition" {
  type    = string
  default = "ENTERPRISE"
}

variable "tier" {
  type        = string
  description = "Machine type. db-custom-4-16384 gives ~4000 max_connections of headroom."
  default     = "db-custom-4-16384"
}

variable "replica_tier" {
  type    = string
  default = "db-custom-2-8192"
}

variable "availability_type" {
  type        = string
  description = "REGIONAL gives an automatic failover replica in a second zone."
  default     = "REGIONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.availability_type)
    error_message = "availability_type must be ZONAL or REGIONAL."
  }
}

variable "disk_size_gb" {
  type    = number
  default = 50
}

variable "disk_autoresize_limit_gb" {
  type        = number
  description = "Ceiling for automatic growth, so a runaway table cannot grow the bill without limit."
  default     = 500
}

variable "max_connections" {
  type        = number
  description = <<-EOT
    Must exceed the worst case across all pods:
      worker  pods x DB_MAX_OPEN_SCHEMAS x DB_MAX_OPEN_CONNS
      web     pods x php-fpm pm.max_children
    plus migrations and Query Insights.
  EOT
  default     = 2000
}

variable "retained_backups" {
  type    = number
  default = 30
}

variable "transaction_log_retention_days" {
  type        = number
  description = "Point-in-time recovery window."
  default     = 7
}

variable "create_read_replica" {
  type    = bool
  default = true
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "app_username" {
  type    = string
  default = "app"
}

variable "tenant_schemas" {
  type        = map(string)
  description = "tenant id => MySQL schema name."
  default = {
    acme        = "tenant_acme"
    whiteknight = "tenant_whiteknight"
    frdm        = "tenant_frdm"
  }
}

variable "labels" {
  type    = map(string)
  default = {}
}
