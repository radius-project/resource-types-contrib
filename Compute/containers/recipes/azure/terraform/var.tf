variable "context" {
  description = "This variable contains Radius recipe context."
  type        = any
}

variable "resource_group_name" {
  description = "The name of the Azure resource group"
  type        = string
}

variable "location" {
  description = "The Azure region for deployment. Defaults to resource group location."
  type        = string
  default     = ""
}

variable "container_group_name" {
  description = "The name of the container group. Defaults to resource name."
  type        = string
  default     = ""
}

variable "os_type" {
  description = "The OS type for the container (Linux or Windows)"
  type        = string
  default     = "Linux"
}

variable "restart_policy" {
  description = "The restart policy for the container (Always, OnFailure, Never)"
  type        = string
  default     = "Always"
}

variable "cpu_cores" {
  description = "The number of CPU cores for the container"
  type        = number
  default     = 1
}

variable "memory_in_gb" {
  description = "The amount of memory in GB for the container"
  type        = number
  default     = 2
}

variable "dns_name_label" {
  description = "The DNS name label for the container. Defaults to resource name with unique suffix."
  type        = string
  default     = ""
}
