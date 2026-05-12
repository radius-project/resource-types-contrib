terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
  }
}

locals {
  properties          = var.context.resource.properties
  resource_name       = var.context.resource.name
  namespace           = var.context.runtime.kubernetes.namespace
  gateway_class_name  = try(local.properties.gatewayClassName, "nginx")
  listeners           = try(local.properties.listeners, [{ name = "http", protocol = "HTTP", port = 80, allowedRoutesFrom = "Same" }])
  resource_id         = var.context.resource.id
  resource_segments   = split("/", local.resource_id)
  resource_group      = length(local.resource_segments) > 4 ? local.resource_segments[4] : ""
  resource_type       = try(var.context.resource.type, length(local.resource_segments) > 6 ? "${local.resource_segments[5]}/${local.resource_segments[6]}" : "")
  resource_type_label = replace(local.resource_type, "/", ".")
  environment_value   = try(tostring(local.properties.environment), "")
  environment_segments = local.environment_value != "" ? split("/", local.environment_value) : []
  environment_label    = length(local.environment_segments) > 0 ? local.environment_segments[length(local.environment_segments) - 1] : ""
  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/environment"    = local.environment_label
    "radapp.io/application"    = var.context.application == null ? "" : var.context.application.name
    "radapp.io/resource-type"  = local.resource_type_label
    "radapp.io/resource-group" = local.resource_group
  }
}

resource "kubernetes_manifest" "gateway" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = local.resource_name
      namespace = local.namespace
      labels    = local.labels
    }
    spec = {
      gatewayClassName = local.gateway_class_name
      listeners = [
        for listener in local.listeners : merge(
          {
            name     = listener.name
            protocol = listener.protocol
            port     = listener.port
            allowedRoutes = {
              namespaces = {
                from = try(listener.allowedRoutesFrom, "Same")
              }
            }
          },
          try(listener.hostname, "") != "" ? { hostname = listener.hostname } : {}
        )
      ]
    }
  }
}

output "result" {
  description = "Resource IDs and values created by the gateway recipe."
  value = {
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/gateway.networking.k8s.io/Gateway/${local.resource_name}"
    ]
    values = {
      gatewayName      = local.resource_name
      gatewayNamespace = local.namespace
    }
  }
}
