# Variable definitions for the Terraform configuration

variable "resource_group_name" {
  description = "Name of the Azure Resource Group"
  type        = string
}

variable "location" {
  description = "Azure region for resource deployment"
  type        = string
  default     = null # Will use resource group location if not specified
}

variable "cg_profile_name" {
  description = "Name of the Container Group Profile"
  type        = string
  default     = "cgp_1"
}

variable "ngroups_name" {
  description = "Name of the NGroups resource"
  type        = string
  default     = "ngroup_lin1_basic"
}

variable "desired_count" {
  description = "Desired count for elastic profile"
  type        = number
  default     = 1
}

variable "prefix_cg" {
  description = "Prefix for container group naming"
  type        = string
  default     = "cg-lin1-basic-"
}

variable "container_image" {
  description = "Container image to deploy"
  type        = string
  default     = "mcr.microsoft.com/azuredocs/aci-helloworld@sha256:565dba8ce20ca1a311c2d9485089d7ddc935dd50140510050345a1b0ea4ffa6e"
}

variable "container_port" {
  description = "Port to expose on the container"
  type        = number
  default     = 80
}

variable "memory_gb" {
  description = "Memory allocation in GB"
  type        = number
  default     = 1.0
}

variable "cpu_cores" {
  description = "CPU allocation"
  type        = number
  default     = 1.0
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    cirrusTestScenario = "lin-1.basic"
    environment        = "development"
  }
}
