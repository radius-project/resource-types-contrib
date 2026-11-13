variable "context" {
  description = "Radius target desired inputs and related delegating Routes."
  type        = any
}

variable "containerAppsEnvironmentName" {
  description = "Name of an existing Azure Container Apps managed environment."
  type        = string
}

variable "containerAppsEnvironmentResourceGroupName" {
  description = "Managed environment resource group; defaults to the configured Radius Azure resource group."
  type        = string
  default     = null
}

variable "containerAppsExternalIngress" {
  description = "Expose TCP outside the ACA environment; requires a VNet and environment-wide unique exposed ports."
  type        = bool
  default     = false
}

variable "containerAppsExposedPorts" {
  description = "Optional map of target TCP port number to exposed TCP port number."
  type        = map(number)
  default     = {}
}

variable "containerAppsDefaultCpu" {
  description = "Default CPU allocation per workload container."
  type        = number
  default     = 0.25
  validation {
    condition     = var.containerAppsDefaultCpu > 0
    error_message = "Default CPU must be positive."
  }
}

variable "containerAppsDefaultMemoryInMib" {
  description = "Default memory allocation per workload container in MiB."
  type        = number
  default     = 512
  validation {
    condition     = var.containerAppsDefaultMemoryInMib > 0 && floor(var.containerAppsDefaultMemoryInMib) == var.containerAppsDefaultMemoryInMib
    error_message = "Default memory must be a positive integer in MiB."
  }
}
