variable "resource_group_name" {
  description = "The name of the resource group where resources will be deployed"
  type        = string
}

variable "api_version" {
  description = "Container Instance API version"
  type        = string
  default     = "2024-09-01-preview"
}

variable "container_group_profile_name" {
  description = "Name of the Container Group Profile"
  type        = string
  default     = "cgp_1"
}

variable "ngroups_name" {
  description = "Name of the NGroups resource"
  type        = string
  default     = "ngroup_confidential_basic"
}

variable "desired_count" {
  description = "Desired number of container instances"
  type        = number
  default     = 1
}

variable "prefix_cg" {
  description = "Prefix for container group naming"
  type        = string
  default     = "cg-confidential-"
}

variable "container_image" {
  description = "Container image to deploy"
  type        = string
  default     = "mcr.microsoft.com/azuredocs/aci-helloworld@sha256:565dba8ce20ca1a311c2d9485089d7ddc935dd50140510050345a1b0ea4ffa6e"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    scenario = "confidential-computing"
    purpose  = "demo"
  }
}
