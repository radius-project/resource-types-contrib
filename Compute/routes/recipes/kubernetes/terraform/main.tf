terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

# Extract route information from context
locals {
  rules        = var.context.resource.properties.rules
  hostnames    = try(var.context.resource.properties.hostnames, [])
  route_kind   = try(var.context.resource.properties.kind, "HTTP")
  resource_id  = var.context.resource.id
  
  # Generate unique suffix for resource naming
  resource_id_hash = substr(sha256(local.resource_id), 0, 10)
  gateway_name     = "gateway-${local.resource_id_hash}"
}

variable "context" {
  description = "Radius-provided deployment context (resource properties and metadata)."
  type = object({
    resource = object({
      id   = string
      name = string
      type = string
      properties = object({
        environment = string
        rules = list(object({
          matches = list(object({
            httpPath = optional(string)
          }))
          destinationContainer = object({
            resourceId        = string
            containerName     = string
            containerPortName = string
          })
        }))
        hostnames = optional(list(string))
        kind      = optional(string)
      })
    })
    runtime = object({
      kubernetes = object({
        namespace = string
      })
    })
  })
}

# Create Gateway for routing
resource "kubernetes_manifest" "gateway" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = local.gateway_name
      namespace = var.context.runtime.kubernetes.namespace
      labels = {
        "app.kubernetes.io/name"      = "radius-gateway"
        "app.kubernetes.io/component" = "gateway"
        "app.kubernetes.io/part-of"   = "radius"
      }
    }
    spec = {
      gatewayClassName = "contour"
      listeners = [
        {
          name     = "http"
          port     = 80
          protocol = "HTTP"
          allowedRoutes = {
            namespaces = {
              from = "Same"
            }
          }
        }
      ]
    }
  }
}

# Create HTTPRoute for HTTP routing using Gateway API
resource "kubernetes_manifest" "http_route" {
  count = local.route_kind == "HTTP" ? 1 : 0
  
  depends_on = [kubernetes_manifest.gateway]
  
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "routes-${local.resource_id_hash}"
      namespace = var.context.runtime.kubernetes.namespace
      labels = {
        "app.kubernetes.io/name"      = "radius-routes"
        "app.kubernetes.io/component" = "httproute"
        "app.kubernetes.io/part-of"   = "radius"
      }
    }
    spec = {
      parentRefs = [
        {
          name      = local.gateway_name
          namespace = var.context.runtime.kubernetes.namespace
        }
      ]
      hostnames = length(local.hostnames) > 0 ? local.hostnames : ["localhost"]
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
              name = "${lower(split("/", rule.destinationContainer.resourceId)[length(split("/", rule.destinationContainer.resourceId)) - 1])}-${rule.destinationContainer.containerName}"
              port = 80
            }
          ]
        }
      ]
    }
  }
}

# Create TLSRoute for TLS routing using Gateway API  
resource "kubernetes_manifest" "tls_route" {
  count = local.route_kind == "TLS" ? 1 : 0
  
  depends_on = [kubernetes_manifest.gateway]
  
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1alpha2"
    kind       = "TLSRoute"
    metadata = {
      name      = "routes-${local.resource_id_hash}"
      namespace = var.context.runtime.kubernetes.namespace
      labels = {
        "app.kubernetes.io/name"      = "radius-routes"
        "app.kubernetes.io/component" = "tlsroute"
        "app.kubernetes.io/part-of"   = "radius"
      }
    }
    spec = {
      parentRefs = [
        {
          name      = local.gateway_name
          namespace = var.context.runtime.kubernetes.namespace
        }
      ]
      hostnames = length(local.hostnames) > 0 ? local.hostnames : ["localhost"]
      rules = [
        for rule in local.rules : {
          backendRefs = [
            {
              name = "${lower(split("/", rule.destinationContainer.resourceId)[length(split("/", rule.destinationContainer.resourceId)) - 1])}-${rule.destinationContainer.containerName}"
              port = 443
            }
          ]
        }
      ]
    }
  }
}

# Create TCPRoute for TCP routing using Gateway API
resource "kubernetes_manifest" "tcp_route" {
  count = local.route_kind == "TCP" ? 1 : 0
  
  depends_on = [kubernetes_manifest.gateway]
  
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1alpha2"
    kind       = "TCPRoute"
    metadata = {
      name      = "routes-${local.resource_id_hash}"
      namespace = var.context.runtime.kubernetes.namespace
      labels = {
        "app.kubernetes.io/name"      = "radius-routes"
        "app.kubernetes.io/component" = "tcproute"
        "app.kubernetes.io/part-of"   = "radius"
      }
    }
    spec = {
      parentRefs = [
        {
          name      = local.gateway_name
          namespace = var.context.runtime.kubernetes.namespace
        }
      ]
      rules = [
        for rule in local.rules : {
          backendRefs = [
            {
              name = "${lower(split("/", rule.destinationContainer.resourceId)[length(split("/", rule.destinationContainer.resourceId)) - 1])}-${rule.destinationContainer.containerName}"
              port = 80
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
  
  depends_on = [kubernetes_manifest.gateway]
  
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1alpha2"
    kind       = "UDPRoute"
    metadata = {
      name      = "routes-${local.resource_id_hash}"
      namespace = var.context.runtime.kubernetes.namespace
      labels = {
        "app.kubernetes.io/name"      = "radius-routes"
        "app.kubernetes.io/component" = "udproute"
        "app.kubernetes.io/part-of"   = "radius"
      }
    }
    spec = {
      parentRefs = [
        {
          name      = local.gateway_name
          namespace = var.context.runtime.kubernetes.namespace
        }
      ]
      rules = [
        for rule in local.rules : {
          backendRefs = [
            {
              name = "${lower(split("/", rule.destinationContainer.resourceId)[length(split("/", rule.destinationContainer.resourceId)) - 1])}-${rule.destinationContainer.containerName}"
              port = 80
            }
          ]
        }
      ]
    }
  }
}

# Output the result in the format expected by Radius
output "result" {
  value = {
    values = {
      hostname    = length(local.hostnames) > 0 ? local.hostnames[0] : "localhost"
      routeCount  = length(local.rules)
      routeKind   = local.route_kind
      gatewayName = local.gateway_name
    }
    secrets = {}
    resources = concat([
      "/planes/kubernetes/local/namespaces/${var.context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/Gateway/${local.gateway_name}"
    ], local.route_kind == "HTTP" ? [
      "/planes/kubernetes/local/namespaces/${var.context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/HTTPRoute/routes-${local.resource_id_hash}"
    ] : local.route_kind == "TLS" ? [
      "/planes/kubernetes/local/namespaces/${var.context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/TLSRoute/routes-${local.resource_id_hash}"
    ] : local.route_kind == "TCP" ? [
      "/planes/kubernetes/local/namespaces/${var.context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/TCPRoute/routes-${local.resource_id_hash}"
    ] : local.route_kind == "UDP" ? [
      "/planes/kubernetes/local/namespaces/${var.context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/UDPRoute/routes-${local.resource_id_hash}"
    ] : [])
  }
}