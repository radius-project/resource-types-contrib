terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
  }
}

# Extract route information from context
locals {
  rules        = var.context.resource.properties.rules
  hostnames    = try(var.context.resource.properties.hostnames, [])
  route_kind   = try(var.context.resource.properties.kind, "HTTP")
  resource_id  = var.context.resource.id
  resource_name = var.context.resource.name
  resource_segments = split(local.resource_id, "/")
  resource_group    = length(local.resource_segments) > 4 ? local.resource_segments[4] : ""
  resource_type     = try(var.context.resource.type, length(local.resource_segments) > 6 ? "${local.resource_segments[5]}/${local.resource_segments[6]}" : "")
  resource_type_label = replace(local.resource_type, "/", ".")
  environment_value = try(tostring(var.context.resource.properties.environment), "")
  environment_segments = local.environment_value != "" ? split("/", local.environment_value) : []
  environment_label = length(local.environment_segments) > 0 ? local.environment_segments[length(local.environment_segments) - 1] : ""
  route_base_labels = {
    "radapp.io/resource"    = local.resource_name
    "radapp.io/environment" = local.environment_label
    "radapp.io/application" = var.context.application == null ? "" : var.context.application.name
    "radapp.io/resource-type"  = local.resource_type_label
    "radapp.io/resource-group" = local.resource_group
  }

  # Generate unique suffix for resource naming
  resource_id_hash = substr(sha256(local.resource_id), 0, 13)
  route_name       = "routes-${local.resource_id_hash}"

  # Assume Gateway already exists - use a default gateway name
  # Platform engineers should configure this via recipe parameters or environment
  gateway_name      = var.gateway_name
  gateway_namespace = var.gateway_namespace
}

# Create HTTPRoute for HTTP routing using Gateway API
resource "kubernetes_manifest" "http_route" {
  count = local.route_kind == "HTTP" ? 1 : 0
  
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = local.route_name
      namespace = var.context.runtime.kubernetes.namespace
      labels = local.route_base_labels
    }
    spec = merge(
      {
        parentRefs = [
          {
            name      = local.gateway_name
            namespace = local.gateway_namespace
          }
        ]
      },
      length(local.hostnames) > 0 ? { hostnames = local.hostnames } : {},
      {
        rules = [
          for rule in local.rules : {
            matches = [
              {
                path = {
                  type  = "PathPrefix"
                  value = try(rule.matches[0].httpPath, "/")
                }
              }
            ]
            backendRefs = [
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
      }
    )
  }
}

# Create TLSRoute for TLS routing using Gateway API
resource "kubernetes_manifest" "tls_route" {
  count = local.route_kind == "TLS" ? 1 : 0
  
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1alpha2"
    kind       = "TLSRoute"
    metadata = {
      name      = local.route_name
      namespace = var.context.runtime.kubernetes.namespace
      labels = local.route_base_labels
    }
    spec = merge(
      {
        parentRefs = [
          {
            name      = local.gateway_name
            namespace = local.gateway_namespace
          }
        ]
      },
      length(local.hostnames) > 0 ? { hostnames = local.hostnames } : {},
      {
        rules = [
          for rule in local.rules : {
            backendRefs = [
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
      }
    )
  }
}

# Create TCPRoute for TCP routing using Gateway API
resource "kubernetes_manifest" "tcp_route" {
  count = local.route_kind == "TCP" ? 1 : 0
  
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1alpha2"
    kind       = "TCPRoute"
    metadata = {
      name      = local.route_name
      namespace = var.context.runtime.kubernetes.namespace
      labels = local.route_base_labels
    }
    spec = {
      parentRefs = [
        {
          name      = local.gateway_name
          namespace = local.gateway_namespace
        }
      ]
      rules = [
        for rule in local.rules : {
          backendRefs = [
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
    }
  }
}

# Create UDPRoute for UDP routing using Gateway API
resource "kubernetes_manifest" "udp_route" {
  count = local.route_kind == "UDP" ? 1 : 0
  
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1alpha2"
    kind       = "UDPRoute"
    metadata = {
      name      = local.route_name
      namespace = var.context.runtime.kubernetes.namespace
      labels = local.route_base_labels
    }
    spec = {
      parentRefs = [
        {
          name      = local.gateway_name
          namespace = local.gateway_namespace
        }
      ]
      rules = [
        for rule in local.rules : {
          backendRefs = [
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
    }
  }
}

output "result" {
  description = "Resource IDs created by the route recipe."
  value = local.route_kind == "HTTP" ? {
    resources = [
      "/planes/kubernetes/local/namespaces/${var.context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/HTTPRoute/${local.route_name}"
    ]
  } : local.route_kind == "TLS" ? {
    resources = [
      "/planes/kubernetes/local/namespaces/${var.context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/TLSRoute/${local.route_name}"
    ]
  } : local.route_kind == "TCP" ? {
    resources = [
      "/planes/kubernetes/local/namespaces/${var.context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/TCPRoute/${local.route_name}"
    ]
  } : local.route_kind == "UDP" ? {
    resources = [
      "/planes/kubernetes/local/namespaces/${var.context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/UDPRoute/${local.route_name}"
    ]
  } : {
    resources = []
  }
}