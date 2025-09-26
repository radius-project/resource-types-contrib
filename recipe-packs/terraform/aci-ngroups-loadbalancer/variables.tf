# Variable definitions for the ACI NGroups LoadBalancer Terraform configuration

variable "resource_group_name" {
  description = "Name of the Azure Resource Group"
  type        = string
}

variable "api_version" {
  description = "API version for Container Instance resources"
  type        = string
  default     = "2024-09-01-preview"
}

variable "ngroups_param_name" {
  description = "Name of the NGroups resource"
  type        = string
  default     = "nGroups_lin100_reg_lb"
}

variable "container_group_profile_name" {
  description = "Name of the Container Group Profile"
  type        = string
  default     = "cgp_1"
}

variable "load_balancer_name" {
  description = "Name of the Load Balancer"
  type        = string
  default     = "slb_1"
}

variable "backend_address_pool_name" {
  description = "Name of the backend address pool"
  type        = string
  default     = "bepool_1"
}

variable "vnet_name" {
  description = "Name of the Virtual Network"
  type        = string
  default     = "vnet_1"
}

variable "subnet_name" {
  description = "Name of the Subnet"
  type        = string
  default     = "subnet_1"
}

variable "network_security_group_name" {
  description = "Name of the Network Security Group"
  type        = string
  default     = "nsg_1"
}

variable "inbound_public_ip_name" {
  description = "Name of the inbound public IP address"
  type        = string
  default     = "inboundPublicIP"
}

variable "outbound_public_ip_name" {
  description = "Name of the outbound public IP address"
  type        = string
  default     = "outboundPublicIP"
}

variable "outbound_public_ip_prefix_name" {
  description = "Name of the NAT gateway public IP prefix"
  type        = string
  default     = "outBoundPublicIPPrefix"
}

variable "nat_gateway_name" {
  description = "Name of the NAT Gateway"
  type        = string
  default     = "natGateway1"
}

variable "frontend_ip_name" {
  description = "Name of the load balancer frontend IP configuration"
  type        = string
  default     = "loadBalancerFrontend"
}

variable "http_rule_name" {
  description = "Name of the HTTP load balancing rule"
  type        = string
  default     = "httpRule"
}

variable "health_probe_name" {
  description = "Name of the health probe"
  type        = string
  default     = "healthProbe"
}

variable "vnet_address_prefix" {
  description = "Address prefix for the Virtual Network"
  type        = string
  default     = "172.19.0.0/16"
}

variable "subnet_address_prefix" {
  description = "Address prefix for the subnet"
  type        = string
  default     = "172.19.1.0/24"
}

variable "desired_count" {
  description = "Desired number of container instances"
  type        = number
  default     = 100
}

variable "zones" {
  description = "Availability zones for the resources"
  type        = list(string)
  default     = []
}

variable "maintain_desired_count" {
  description = "Whether to maintain the desired count"
  type        = bool
  default     = true
}

variable "domain_name_label" {
  description = "Domain name label for the public IP"
  type        = string
  default     = "ngroupsdemo"
}

variable "inbound_nat_rule_name" {
  description = "Name of the inbound NAT rule"
  type        = string
  default     = "inboundNatRule"
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
    cirrusTestScenario    = "lin-100.regional.loadbalancer"
    "reprovision.enabled" = "true"
    environment          = "development"
  }
}
