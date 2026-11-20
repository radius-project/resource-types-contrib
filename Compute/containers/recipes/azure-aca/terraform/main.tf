terraform {
  required_version = ">= 1.7"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.50"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}

locals {
  properties = var.context.resource.properties
  containers = local.properties.containers
  incoming   = try(var.context.resource.incomingReferences, [])
  name       = "aca-${substr(sha256(lower(var.context.resource.id)), 0, 20)}"
  regular    = { for name, container in local.containers : name => container if !try(container.initContainer, false) }
  rules = flatten([
    for route in local.incoming : [
      for rule in route.properties.rules : {
        destination = rule.destinationContainer
        matches     = rule.matches
      }
    ]
  ])
  declared_ports = flatten([
    for name, container in local.regular : [
      for port in try(container.ports, {}) : {
        container_name = name
        port           = port.containerPort
        protocol       = try(port.protocol, "TCP")
      }
    ]
  ])
  # Sort numerically rather than lexically so additions/removals choose the same primary port in both drivers.
  target_ports  = [for port in sort(distinct([for rule in local.rules : format("%05d", rule.destination.containerPort)])) : tonumber(port)]
  exposed_ports = [for port in local.target_ports : lookup(var.containerAppsExposedPorts, tostring(port), port)]
  valid_routes = alltrue([
    for route in local.incoming :
    route.type == "Radius.Compute/routes" &&
    try(route.properties.kind, "HTTP") == "TCP" &&
    length(try(route.properties.hostnames, [])) == 0 &&
    length(route.properties.rules) > 0 &&
    length(distinct([for rule in route.properties.rules : "${rule.destinationContainer.containerName}:${rule.destinationContainer.containerPort}"])) == 1
  ])
  valid_rules = alltrue([
    for rule in local.rules :
    length(rule.matches) == 0 &&
    lower(rule.destination.resourceId) == lower(var.context.resource.id) &&
    anytrue([for port in local.declared_ports : port.container_name == rule.destination.containerName && port.port == rule.destination.containerPort && port.protocol == "TCP"])
  ])
  valid_ports = (
    length(local.target_ports) <= 6 &&
    length(distinct(local.exposed_ports)) == length(local.exposed_ports) &&
    alltrue([for port in concat(local.target_ports, local.exposed_ports) : port >= 1 && port <= 65535 && floor(port) == port && port != 36985]) &&
    alltrue([for port in local.exposed_ports : !var.containerAppsExternalIngress || !contains([80, 443], port)]) &&
    alltrue([for port in local.declared_ports : length(distinct([for other in local.declared_ports : other.container_name if other.port == port.port])) == 1 && port.protocol == "TCP"])
  )
  connections = {
    for name, connection in try(var.context.resource.connections, {}) : name => connection
    if !try(local.properties.connections[name].disableDefaultEnvVars, false)
  }
  excluded_properties = ["recipe", "status", "provisioningState", "resourceProvisioning", "properties", "secrets"]
  connection_env = merge({}, [
    for name, connection in local.connections : {
      for key, value in merge(connection, try(connection.properties, {})) :
      upper("CONNECTION_${name}_${key}") => can(tostring(value)) ? tostring(value) : jsonencode(value)
      if !contains(local.excluded_properties, key) && value != null
    }
  ]...)
  valid_connections = alltrue([
    for connection in local.connections :
    try(connection.type, "") != "Radius.Security/secrets" && length(try(connection.secrets, {})) == 0
  ])
  valid_containers = alltrue([
    for container in local.containers :
    try(container.workingDir, "") == "" &&
    length(try(container.volumeMounts, [])) == 0 &&
    try(container.readinessProbe, null) == null &&
    try(container.livenessProbe, null) == null &&
    alltrue([for env in try(container.env, {}) : try(env.valueFrom, null) == null && try(env.value, null) != null]) &&
    (try(container.resources.requests.cpu, null) == null || try(container.resources.limits.cpu, null) == null || try(tonumber(container.resources.requests.cpu) == tonumber(container.resources.limits.cpu), false)) &&
    (try(container.resources.requests.memoryInMib, null) == null || try(container.resources.limits.memoryInMib, null) == null || try(container.resources.requests.memoryInMib == container.resources.limits.memoryInMib, false))
  ])
  supported_workload = (
    length(try(local.properties.volumes, {})) == 0 &&
    length(try(local.properties.extensions, {})) == 0 &&
    length(try(local.properties.platformOptions, {})) == 0 &&
    try(local.properties.autoScaling, null) == null &&
    try(local.properties.restartPolicy, "Always") == "Always" &&
    try(local.properties.replicas, 1) >= 1 &&
    length(distinct([for name in keys(local.containers) : lower(name)])) == length(local.containers) &&
    length(local.regular) > 0
  )
  allocations = {
    for name, container in local.containers : name => {
      cpu    = tonumber(coalesce(try(container.resources.limits.cpu, null), try(container.resources.requests.cpu, null), var.containerAppsDefaultCpu))
      memory = coalesce(try(container.resources.limits.memoryInMib, null), try(container.resources.requests.memoryInMib, null), var.containerAppsDefaultMemoryInMib)
    }
  }
  workload = {
    for name, container in local.containers : name => {
      name    = lower(name)
      image   = container.image
      command = coalesce(try(container.command, null), [])
      args    = coalesce(try(container.args, null), [])
      env     = [for key, value in merge(local.connection_env, { for key, env in try(container.env, {}) : key => try(env.value, "") }) : { name = key, value = value }]
      resources = {
        cpu    = local.allocations[name].cpu
        memory = "${local.allocations[name].memory / 1024}Gi"
      }
    }
  }
}

data "azurerm_container_app_environment" "existing" {
  name                = var.containerAppsEnvironmentName
  resource_group_name = coalesce(var.containerAppsEnvironmentResourceGroupName, var.context.azure.resourceGroup.name)
}

data "azurerm_resource_group" "existing" {
  name = var.context.azure.resourceGroup.name
}

resource "azapi_resource" "workload" {
  type      = "Microsoft.App/containerApps@2025-07-01"
  name      = local.name
  parent_id = data.azurerm_resource_group.existing.id
  location  = data.azurerm_container_app_environment.existing.location
  tags      = { "radapp.io-resource" = var.context.resource.name }
  # Do not let a read/merge of old configuration retain deleted ingress.
  ignore_null_property   = false
  response_export_values = ["properties.configuration.ingress.fqdn"]
  body = {
    properties = {
      managedEnvironmentId = data.azurerm_container_app_environment.existing.id
      configuration = {
        activeRevisionsMode = "Single"
        ingress = length(local.target_ports) == 0 ? null : {
          external    = var.containerAppsExternalIngress
          transport   = "tcp"
          targetPort  = local.target_ports[0]
          exposedPort = local.exposed_ports[0]
          additionalPortMappings = [
            for index, port in local.target_ports : {
              external    = var.containerAppsExternalIngress
              targetPort  = port
              exposedPort = local.exposed_ports[index]
            } if index > 0
          ]
          traffic = [{ latestRevision = true, weight = 100 }]
        }
      }
      template = {
        scale = {
          minReplicas = try(local.properties.replicas, 1)
          maxReplicas = try(local.properties.replicas, 1)
        }
        containers = [
          for name, container in local.workload : container if !try(local.containers[name].initContainer, false)
        ]
        initContainers = [
          for name, container in local.workload : container if try(local.containers[name].initContainer, false)
        ]
      }
    }
  }

  lifecycle {
    precondition {
      condition     = local.valid_routes && local.valid_rules && local.valid_ports
      error_message = "ACA TCP requires unconditional TCP routes, all rules of each route selecting the same declared workload/port, at most six unique ports and no port conflicts. HTTP/TLS/UDP and host/match conditions are unsupported."
    }
    precondition {
      condition     = local.valid_containers && local.valid_connections && local.supported_workload
      error_message = "ACA TCP does not support probes, workingDir, volumes, extensions, platformOptions, autoscaling or secret references. Require at least one regular container, positive replicas, unique normalized names and equal requests/limits when both are set."
    }
    precondition {
      condition     = alltrue([for allocation in local.allocations : allocation.memory > 0 && allocation.memory % 256 == 0])
      error_message = "ACA memory must be a positive multiple of 256 MiB to represent Gi with at most two decimal places."
    }
  }
}

output "result" {
  value = {
    resources = [azapi_resource.workload.id]
    values = {
      hosts = {
        for name in keys(local.regular) : name => var.containerAppsExternalIngress ? azapi_resource.workload.output.properties.configuration.ingress.fqdn : local.name
        if anytrue([for rule in local.rules : rule.destination.containerName == name])
      }
    }
    delegatedOutputs = [
      for route in local.incoming : {
        id       = route.id
        revision = route.revision
        values = {
          listener = {
            hostname = var.containerAppsExternalIngress ? azapi_resource.workload.output.properties.configuration.ingress.fqdn : local.name
            port     = local.exposed_ports[index(local.target_ports, min([for rule in route.properties.rules : rule.destinationContainer.containerPort]...))]
            protocol = "TCP"
          }
        }
      }
    ]
  }
}
