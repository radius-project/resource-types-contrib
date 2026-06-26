terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
  }
}

variable "context" {
  description = "This variable contains Radius Recipe context."
  type = any
}

// No verified Terraform module exists for Redis on Kubernetes.
// This recipe uses the kubernetes provider directly.

variable "memory" {
  description = "Memory limits for the Redis container"
  type = map(object({
    memoryRequest = string
  }))
  default = {
    S = {
      memoryRequest = "128Mi"
    },
    M = {
      memoryRequest = "256Mi"
    },
    L = {
      memoryRequest = "512Mi"
    }
  }
}

locals {
  resource_name      = var.context.resource.name
  application_name   = var.context.application != null ? var.context.application.name : ""
  environment_name   = var.context.environment != null ? var.context.environment.name : ""
  resource_group     = element(split("/", var.context.resource.id), 5)
  namespace          = var.context.runtime.kubernetes.namespace
  port               = 6379
  tag                = "7-alpine"
  secret_name        = try(var.context.resource.properties.secretName, "")
  has_secret         = local.secret_name != ""
  size_value         = try(var.context.resource.properties.size, "S")

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }
}

resource "kubernetes_deployment" "redis" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    selector {
      match_labels = {
        "radapp.io/resource" = local.resource_name
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        container {
          name  = "redis"
          image = "redis:${local.tag}"

          port {
            container_port = local.port
          }

          resources {
            requests = {
              memory = var.memory[local.size_value].memoryRequest
            }
          }

          args = local.has_secret ? ["redis-server", "--requirepass", "$(REDIS_PASSWORD)"] : ["redis-server"]

          dynamic "env" {
            for_each = local.has_secret ? [1] : []
            content {
              name = "REDIS_PASSWORD"
              value_from {
                secret_key_ref {
                  name = local.secret_name
                  key  = "PASSWORD"
                }
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    type = "ClusterIP"

    selector = {
      "radapp.io/resource" = local.resource_name
    }

    port {
      port = local.port
    }
  }
}

output "result" {
  value = {
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${local.resource_name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${local.resource_name}"
    ]
    values = {
      host     = "${kubernetes_service.redis.metadata[0].name}.${kubernetes_service.redis.metadata[0].namespace}.svc.cluster.local"
      port     = local.port
    }
  }
}
