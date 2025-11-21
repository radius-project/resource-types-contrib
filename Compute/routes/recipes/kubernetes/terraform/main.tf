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

  # Generate unique suffix for resource naming
  resource_id_hash = substr(sha256(local.resource_id), 0, 10)

  # Assume Gateway already exists - use a default gateway name
  # Platform engineers should configure this via recipe parameters or environment
  gateway_name = "default-gateway"
}

# Create HTTPRoute for HTTP routing using Gateway API
resource "kubernetes_manifest" "http_route" {
  count = local.route_kind == "HTTP" ? 1 : 0
  
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
    spec = merge(
      {
        parentRefs = [
          {
            name      = local.gateway_name
            namespace = var.context.runtime.kubernetes.namespace
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
                name = lower(split("/", rule.destinationContainer.resourceId)[length(split("/", rule.destinationContainer.resourceId)) - 1])
                port = try(rule.destinationContainer.containerPort, 80)
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
      name      = "routes-${local.resource_id_hash}"
      namespace = var.context.runtime.kubernetes.namespace
      labels = {
        "app.kubernetes.io/name"      = "radius-routes"
        "app.kubernetes.io/component" = "tlsroute"
        "app.kubernetes.io/part-of"   = "radius"
      }
    }
    spec = merge(
      {
        parentRefs = [
          {
            name      = local.gateway_name
            namespace = var.context.runtime.kubernetes.namespace
          }
        ]
      },
      length(local.hostnames) > 0 ? { hostnames = local.hostnames } : {},
      {
        rules = [
          for rule in local.rules : {
            backendRefs = [
              {
                name = lower(split("/", rule.destinationContainer.resourceId)[length(split("/", rule.destinationContainer.resourceId)) - 1])
                port = try(rule.destinationContainer.containerPort, 443)
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
              name = lower(split("/", rule.destinationContainer.resourceId)[length(split("/", rule.destinationContainer.resourceId)) - 1])
              port = try(rule.destinationContainer.containerPort, 80)
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
              name = lower(split("/", rule.destinationContainer.resourceId)[length(split("/", rule.destinationContainer.resourceId)) - 1])
              port = try(rule.destinationContainer.containerPort, 80)
            }
          ]
        }
      ]
    }
  }
}