variable "name" {
  description = "The name of the MongoDB instance."
  type        = string
}

variable "mongodb_version" {
  description = "MongoDB version"
  type        = string
  default     = "6.0"
}

variable "replicas" {
  description = "Number of replicas"
  type        = number
  default     = 1
}

variable "storage_size" {
  description = "Persistent volume size"
  type        = string
  default     = "10Gi"
}

variable "storage_class" {
  description = "Kubernetes storage class"
  type        = string
  default     = "standard"
}

variable "username" {
  description = "Admin username"
  type        = string
  default     = "admin"
}

variable "password" {
  description = "Admin password"
  type        = string
  sensitive   = true
}

variable "persistence" {
  description = "Enable persistence"
  type        = bool
  default     = true
}

variable "backup_enabled" {
  description = "Enable backups"
  type        = bool
  default     = false
}

variable "backup_schedule" {
  description = "Cron schedule for backups"
  type        = string
  default     = ""
}

variable "resources" {
  description = "Resource requests and limits"
  type = object({
    requests = optional(object({
      cpu    = string
      memory = string
    }), { cpu = "250m", memory = "512Mi" })
    limits = optional(object({
      cpu    = string
      memory = string
    }), { cpu = "500m", memory = "1Gi" })
  })
  default = {}
}
