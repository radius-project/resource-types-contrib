terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
  }
}

variable "context" {
  description = "Radius-provided object containing information about the resource calling the Recipe."
  type = any
}

variable "memory" {
  description = "Memory limits for the Redis container"
  type = map(object({
    memoryRequest = string
    memoryLimit  = string
  }))
  default = {
    S = {
      memoryRequest = "512Mi"
      memoryLimit   = "1024Mi"
    },
    M = {
      memoryRequest = "1Gi"
      memoryLimit   = "2Gi"
    }
  }
}

locals {
  uniqueName = var.context.resource.name
  port     = 6379
  namespace = var.context.runtime.kubernetes.namespace
}

resource "kubernetes_deployment" "redis" {
  metadata {
    name = local.uniqueName
    namespace = local.namespace
    labels = {
      app = "redis"
    }
  }
  spec {
    selector {
      match_labels = {
        app = "redis"
        resource = local.uniqueName
      }
    }
    template {
      metadata {
        labels = {
          app = "redis"
          resource = local.uniqueName
        }
      }
      spec {
        container {
          name  = "redis"
          image = "redis:6"
          resources {
            requests = {
              memory = var.memory[var.context.resource.properties.capacity].memoryRequest
              }
              limits = {
                memory= var.memory[var.context.resource.properties.capacity].memoryLimit
              }
            }
          port {
            container_port = local.port
          }

        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
  metadata {
    name = local.uniqueName
    namespace = local.namespace
  }
  spec {
    type = "ClusterIP"
    selector = {
      app = "redis"
      resource = local.uniqueName
    }
    port {
      port        = local.port
      target_port = local.port
    }
  }
}

output "result" {
  value = {
    values = {
      host = "${kubernetes_service.redis.metadata[0].name}.${kubernetes_service.redis.metadata[0].namespace}.svc.cluster.local"
      port = local.port
    }
  }
}