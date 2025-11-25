terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
  }
}

# ========================================
# Common Radius variables
# ========================================

variable "context" {
  description = "The Radius Recipe context variable. See https://docs.radapp.io/reference/context-schema/."
  type = any
}

locals {
  resource_name = var.context.resource.name
  namespace     = var.context.runtime.kubernetes.namespace
  
  # Extract resource properties
  resource_properties = try(var.context.resource.properties, {})

  # Extract last segment from environment path for labels
  environment_id    = try(local.resource_properties.environment, "")
  environment_parts = local.environment_id != "" ? split("/", local.environment_id) : []
  environment_label = length(local.environment_parts) > 0 ? local.environment_parts[length(local.environment_parts) - 1] : ""

  # Extract resource group name
  resource_group_name = split("/", var.context.resource.id)[4]

  # Application name
  application_name = var.context.application != null ? var.context.application.name : ""

  # Build labels
  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_label
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group_name
  }
}

# ========================================
# PostgreSQL variables
# ========================================

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
  port = 5432
    
  # Get the secret reference. Should be only a single connected resource.
  radius_connections_map      = try(var.context.resource.connections, {})
  radius_connection_list      = values(local.radius_connections_map)
  radius_first_connection     = try(local.radius_connection_list[0], null)
  radius_secret_name          = local.radius_first_connection != null ? lookup(local.radius_first_connection, "secretName", null) : null

}

# ========================================
# PostgreSQL resources
# ========================================

resource "kubernetes_deployment" "postgresql" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    selector {
      match_labels = {
        app = "postgres"
      }
    }

    template {
      metadata {
        labels = merge(local.labels, {
          app = "postgres"
        })
      }

      spec {
        container {
          name  = "postgres"
          image = "postgres:16-alpine"
          resources {
            requests = {
              memory = var.memory[var.context.resource.properties.size].memoryRequest
              }
            }
          port {
            container_port = local.port
          }
          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = local.radius_secret_name
                key  = "username"
              }
            }
          }
          env {
            name  = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = local.radius_secret_name
                key  = "password"
              }
            }
          }
          env {
            name  = "POSTGRES_DB"
            value = "postgres_db"
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
      app = "postgres"
    }
    port {
      port = local.port
    } 
  }
}

# ========================================
# Output Radius result 
# ========================================

output "result" {
  value = {
    resources = [
        "/planes/kubernetes/local/namespaces/${kubernetes_service.postgres.metadata[0].namespace}/providers/core/Service/${kubernetes_service.postgres.metadata[0].name}",
        "/planes/kubernetes/local/namespaces/${kubernetes_deployment.postgresql.metadata[0].namespace}/providers/apps/Deployment/${kubernetes_deployment.postgresql.metadata[0].name}"
    ]
    values = {
      host = "${kubernetes_service.postgres.metadata[0].name}.${kubernetes_service.postgres.metadata[0].namespace}.svc.cluster.local"
      port = local.port
      database = "postgres_db"
    }
  }
}
