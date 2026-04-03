terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
  }
}

# ========================================
# Local Values - Basic Configuration
# ========================================
locals {
  resource_name = var.context.resource.name

  # Extract resource properties
  resource_properties = try(var.context.resource.properties, {})
  containers          = try(local.resource_properties.containers, {})

  # Restart policy - normalize to ACI expected values
  restart_policy_raw = try(local.resource_properties.restartPolicy, "Always")
  restart_policy     = local.restart_policy_raw == "Never" ? "Never" : local.restart_policy_raw == "OnFailure" ? "OnFailure" : "Always"
}

# ========================================
# Container Processing
# ========================================
locals {
  # Build container specs, filtering out init containers (not supported by ACI)
  container_specs = {
    for name, config in local.containers : name => {
      name    = name
      image   = config.image
      command = try(config.command, null)
      args    = try(config.args, null)

      # CPU and memory - ACI requires numeric values
      # Default to 0.5 vCPU and 0.5 GB if not specified
      cpu    = 0.5
      memory = 0.5

      # Build complete commands array (command + args concatenated)
      # Only set if there's actually a command
      has_commands = try(config.command, null) != null
      commands_list = try(config.command, null) != null ? (
        try(config.args, null) != null ?
          concat(config.command, config.args) :
          config.command
      ) : []

      # Ports
      ports = [
        for port_name, port_config in try(config.ports, {}) : {
          port     = port_config.containerPort
          protocol = try(port_config.protocol, "TCP")
        }
      ]

      # Environment variables - only include those with values
      env_vars = {
        for env_name, env_config in try(config.env, {}) :
        env_name => env_config.value
        if try(env_config.value, null) != null
      }
    }
    # Filter out init containers - ACI doesn't support them
    if !try(config.initContainer, false)
  }
}

# ========================================
# Azure Resource Group Data Source
# ========================================
data "azurerm_resource_group" "rg" {
  name = var.context.azure.resourceGroup.name
}

# ========================================
# Azure Container Group
# ========================================
resource "azurerm_container_group" "container_group" {
  name                = local.resource_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = var.context.azure.resourceGroup.name
  os_type             = "Linux"
  restart_policy      = local.restart_policy

  # Create a container for each spec
  dynamic "container" {
    for_each = local.container_specs
    content {
      name   = container.value.name
      image  = container.value.image
      cpu    = container.value.cpu
      memory = container.value.memory

      # Commands - only set if container has a command defined
      commands = container.value.has_commands ? container.value.commands_list : null

      # Ports
      dynamic "ports" {
        for_each = container.value.ports
        content {
          port     = ports.value.port
          protocol = ports.value.protocol
        }
      }

      # Environment variables - only set if there are any
      environment_variables = length(container.value.env_vars) > 0 ? container.value.env_vars : null
    }
  }
}

# ========================================
# Outputs
# ========================================
output "result" {
  value = {
    resources = [azurerm_container_group.container_group.id]
  }
}
