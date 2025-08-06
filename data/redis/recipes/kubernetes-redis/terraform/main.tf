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
  description = "Memory limits for the PostgreSQL container"
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

resource "kubernetes_deployment" "redis" {
  metadata {
    name = "redis-${sha512(var.context.resource.id)}"
    namespace = var.context.runtime.kubernetes.namespace
    labels = {
      app = "redis"
    }
  }
  spec {
    selector {
      match_labels = {
        app = "redis"
        resource = var.context.resource.name
      }
    }
    template {
      metadata {
        labels = {
          app = "redis"
          resource = var.context.resource.name
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
            container_port = 6379
          }

        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
  metadata {
    name = "redis-${sha512(var.context.resource.id)}"
    namespace = var.context.runtime.kubernetes.namespace
  }
  spec {
    type = "ClusterIP"
    selector = {
      app = "redis"
      resource = var.context.resource.name
    }
    port {
      port        = 6379
      target_port = "6379"
    }
  }
}

output "result" {
  value = {
    values = {
      host = "${kubernetes_service.metadata.name}.${kubernetes_service.metadata.namespace}.svc.cluster.local"
      port = kubernetes_service.spec.port[0].port
      username = ""
    }
    secrets = {
      password = ""
    }
    // UCP resource IDs
    resources = [
        "/planes/kubernetes/local/namespaces/${kubernetes_service.metadata.namespace}/providers/core/Service/${kubernetes_service.metadata.name}",
        "/planes/kubernetes/local/namespaces/${kubernetes_deployment.metadata.namespace}/providers/apps/Deployment/${kubernetes_deployment.metadata.name}"
    ]
  }
  description = "The result of the Recipe. Must match the target resource's schema."
  sensitive = true
}