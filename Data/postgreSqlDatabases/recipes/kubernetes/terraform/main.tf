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

variable "memory" {
  description = "Memory limits for the PostgreSQL container"
  type = map(object({
    memoryRequest = string
  }))
  default = {
    S = {
      memoryRequest = "512Mi"
    },
    M = {
      memoryRequest = "1Gi"
    },
    L = {
      memoryRequest = "2Gi"
    }
  }
}

locals {
  resource_name      = var.context.resource.name
  application_name   = var.context.application != null ? var.context.application.name : ""
  environment_name   = var.context.environment != null ? var.context.environment.name : ""
  resource_group     = element(split("/", var.context.resource.id), 5)
  namespace          = var.context.runtime.kubernetes.namespace
  port               = 5432
  tag                = "16-alpine"
  db_secret_name     = var.context.resource.properties.secretName
  database           = try(var.context.resource.properties.database, "postgres_db")
  size_value         = try(var.context.resource.properties.size, "S")

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }
}

resource "kubernetes_deployment" "postgresql" {
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
          name  = "postgres"
          image = "postgres:${local.tag}"

          port {
            container_port = local.port
          }

          resources {
            requests = {
              memory = var.memory[local.size_value].memoryRequest
            }
          }

          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = local.db_secret_name
                key  = "USERNAME"
              }
            }
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = local.db_secret_name
                key  = "PASSWORD"
              }
            }
          }

          env {
            name  = "POSTGRES_DB"
            value = local.database
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "postgres" {
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
      host     = "${kubernetes_service.postgres.metadata[0].name}.${kubernetes_service.postgres.metadata[0].namespace}.svc.cluster.local"
      port     = local.port
      database = local.database
    }
  }
}
