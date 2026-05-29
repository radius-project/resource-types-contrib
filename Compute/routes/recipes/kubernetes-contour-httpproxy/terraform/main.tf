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
  rules         = var.context.resource.properties.rules
  hostnames     = try(var.context.resource.properties.hostnames, [])
  route_kind    = try(var.context.resource.properties.kind, "HTTP")
  resource_id   = var.context.resource.id
  resource_name = var.context.resource.name
  namespace     = var.context.runtime.kubernetes.namespace

  resource_segments    = split(local.resource_id, "/")
  resource_group       = length(local.resource_segments) > 4 ? local.resource_segments[4] : ""
  resource_type        = try(var.context.resource.type, length(local.resource_segments) > 6 ? "${local.resource_segments[5]}/${local.resource_segments[6]}" : "")
  resource_type_label  = replace(local.resource_type, "/", ".")
  environment_value    = try(tostring(var.context.resource.properties.environment), "")
  environment_segments = local.environment_value != "" ? split("/", local.environment_value) : []
  environment_label    = length(local.environment_segments) > 0 ? local.environment_segments[length(local.environment_segments) - 1] : ""

  httpproxy_name = local.resource_name
  fqdn           = try(local.hostnames[0], var.hostname)

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/environment"    = local.environment_label
    "radapp.io/application"    = var.context.application == null ? "" : var.context.application.name
    "radapp.io/resource-type"  = local.resource_type_label
    "radapp.io/resource-group" = local.resource_group
  }

  routes = flatten([
    for rule in local.rules : [
      for match in try(rule.matches, [{}]) : {
        conditions = [
          {
            prefix = try(match.httpPath, "/")
          }
        ]
        services = [
          {
            name = lower(
              try(rule.destinationContainer.containerName, "") != ""
              ? "${split("/", rule.destinationContainer.resourceId)[length(split("/", rule.destinationContainer.resourceId)) - 1]}-${rule.destinationContainer.containerName}"
              : split("/", rule.destinationContainer.resourceId)[length(split("/", rule.destinationContainer.resourceId)) - 1]
            )
            port = rule.destinationContainer.containerPort
          }
        ]
      }
    ]
  ])
}

resource "kubernetes_manifest" "http_proxy" {
  count = local.route_kind == "HTTP" ? 1 : 0

  manifest = {
    apiVersion = "projectcontour.io/v1"
    kind       = "HTTPProxy"
    metadata = {
      name      = local.httpproxy_name
      namespace = local.namespace
      labels    = local.labels
    }
    spec = {
      virtualhost = {
        fqdn = local.fqdn
      }
      routes = local.routes
    }
  }
}

output "result" {
  description = "Resource IDs created by the Contour HTTPProxy route recipe."
  value = local.route_kind == "HTTP" ? {
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/projectcontour.io/HTTPProxy/${local.httpproxy_name}"
    ]
    } : {
    resources = []
  }
}
