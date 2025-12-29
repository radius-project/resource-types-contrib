terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# ========================================
# Local Values - Basic Configuration
# ========================================
locals {
  resource_name       = var.context.resource.name
  resource_properties = try(var.context.resource.properties, {})
  containers          = try(local.resource_properties.containers, {})
  
  # Get the first container's image (typically 'web')
  first_container_key   = keys(local.containers)[0]
  first_container       = local.containers[local.first_container_key]
  container_image       = try(local.first_container.image, "nginx:alpine")
  
  # Container ports - get first port if defined
  container_ports = try(local.first_container.ports, {})
  first_port_key  = length(keys(local.container_ports)) > 0 ? keys(local.container_ports)[0] : null
  first_port      = local.first_port_key != null ? local.container_ports[local.first_port_key] : null
  container_port  = try(local.first_port.containerPort, 80)
  
  # Environment variables
  container_env = try(local.first_container.env, {})
  env_vars = [
    for env_name, env_config in local.container_env : {
      name  = env_name
      value = try(env_config.value, "")
    }
  ]
}

# ========================================
# Data Sources
# ========================================
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# ========================================
# Azure Container Instance
# ========================================
resource "azurerm_container_group" "aci" {
  name                = var.container_group_name != "" ? var.container_group_name : local.resource_name
  location            = var.location != "" ? var.location : data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  os_type             = var.os_type
  restart_policy      = var.restart_policy

  container {
    name   = local.first_container_key
    image  = local.container_image
    cpu    = var.cpu_cores
    memory = var.memory_in_gb

    ports {
      port     = local.container_port
      protocol = "TCP"
    }

    dynamic "environment_variables" {
      for_each = { for env in local.env_vars : env.name => env.value }
      content {
        name  = environment_variables.key
        value = environment_variables.value
      }
    }
  }

  ip_address_type = "Public"
  dns_name_label  = var.dns_name_label != "" ? var.dns_name_label : "${local.resource_name}-${substr(md5(data.azurerm_resource_group.rg.id), 0, 8)}"

  tags = {
    "radapp.io/resource" = local.resource_name
  }
}

# ========================================
# Outputs
# ========================================
output "result" {
  description = "Recipe result"
  value = {
    resources = [
      azurerm_container_group.aci.id
    ]
    values = {
      containerIPv4Address = azurerm_container_group.aci.ip_address
      containerFqdn        = azurerm_container_group.aci.fqdn
    }
  }
}
