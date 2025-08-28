# Variable definitions for the NGroups Gateway Terraform configuration

variable "resource_group_name" {
  description = "Name of the Azure Resource Group"
  type        = string
}

variable "api_version" {
  description = "API version for Container Instance resources"
  type        = string
  default     = "2024-09-01-preview"
}

variable "ngroups_name_param" {
  description = "Name of the NGroups resource"
  type        = string
  default     = "nGroups_lin100_regional_ag"
}

variable "container_group_profile_name" {
  description = "Name of the Container Group Profile"
  type        = string
  default     = "cgp"
}

variable "application_gateway_name" {
  description = "Name of the Application Gateway"
  type        = string
  default     = "agw1"
}

variable "public_ip_name" {
  description = "Name of the Public IP address"
  type        = string
  default     = "publicIP"
}

variable "backend_address_pool_name" {
  description = "Name of the backend address pool"
  type        = string
  default     = "bepool"
}

variable "vnet_name" {
  description = "Name of the Virtual Network"
  type        = string
  default     = "vnet1"
}

variable "network_security_group_name" {
  description = "Name of the Network Security Group"
  type        = string
  default     = "nsg1"
}

variable "desired_count" {
  description = "Desired number of container instances"
  type        = number
  default     = 100
}

variable "maintain_desired_count" {
  description = "Whether to maintain the desired count"
  type        = bool
  default     = true
}

variable "zones" {
  description = "Availability zones for the resources"
  type        = list(string)
  default     = []
}

variable "vnet_address_prefix" {
  description = "Address prefix for the Virtual Network"
  type        = string
  default     = "172.16.0.0/23"
}

variable "aci_subnet_address_prefix" {
  description = "Address prefix for the ACI subnet"
  type        = string
  default     = "172.16.0.0/25"
}

variable "app_gateway_subnet_address_prefix" {
  description = "Address prefix for the Application Gateway subnet"
  type        = string
  default     = "172.16.1.0/25"
}

variable "aci_subnet_name" {
  description = "Name of the ACI subnet"
  type        = string
  default     = "aciSubnet"
}

variable "app_gateway_subnet_name" {
  description = "Name of the Application Gateway subnet"
  type        = string
  default     = "appgatewaySubnet"
}

variable "ddos_protection_plan_name" {
  description = "Name of the DDoS protection plan"
  type        = string
  default     = "ddosProtectionPlan"
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
    cirrusTestScenario    = "lin-100.regional.appgateway"
    "reprovision.enabled" = "true"
    environment          = "development"
  }
}
