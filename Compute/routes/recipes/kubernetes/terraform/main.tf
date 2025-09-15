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
  rules     = var.context.resource.properties.rules
  hostnames = try(var.context.resource.properties.hostnames, [])
  route_kind = try(var.context.resource.properties.kind, "HTTP")
  
  # Generate unique suffix for resource naming
  resource_id_hash = substr(sha256(var.context.resource.id), 0, 10)
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

# Create Kubernetes Ingress for HTTP routing
resource "kubernetes_ingress_v1" "routes" {
  count = local.route_kind == "HTTP" ? 1 : 0
  
  metadata {
    name      = "routes-${local.resource_id_hash}"
    namespace = var.context.runtime.kubernetes.namespace
    
    labels = {
      "app.kubernetes.io/name"      = "radius-routes"
      "app.kubernetes.io/component" = "ingress"
      "app.kubernetes.io/part-of"   = "radius"
    }
    
    annotations = {
      "nginx.ingress.kubernetes.io/rewrite-target" = "/$1"
    }
  }
  
  spec {
    rule {
      host = length(local.hostnames) > 0 ? local.hostnames[0] : "localhost"
      
      http {
        dynamic "path" {
          for_each = local.rules
          content {
            path      = "${try(path.value.matches[0].httpPath, "/")}(.*)"
            path_type = "Prefix"
            
            backend {
              service {
                name = "${lower(split("/", path.value.destinationContainer.resourceId)[length(split("/", path.value.destinationContainer.resourceId)) - 1])}-${path.value.destinationContainer.containerName}"
                port {
                  name = path.value.destinationContainer.containerPortName
                }
              }
            }
          }
        }
      }
    }
  }
}

# Output the result in the format expected by Radius
output "result" {
  value = {
    values = {
      hostname   = length(local.hostnames) > 0 ? local.hostnames[0] : "localhost"
      routeCount = length(local.rules)
      routeKind  = local.route_kind
    }
    secrets = {}
    resources = local.route_kind == "HTTP" ? [
      "/planes/kubernetes/local/namespaces/${var.context.runtime.kubernetes.namespace}/providers/networking.k8s.io/Ingress/routes-${local.resource_id_hash}"
    ] : []
  }
}