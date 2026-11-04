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
  type        = any
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
  resource_name    = var.context.resource.name
  application_name = var.context.application != null ? var.context.application.name : ""
  environment_name = var.context.environment != null ? var.context.environment.name : ""
  resource_group   = element(split("/", var.context.resource.id), 5)
  namespace        = var.context.runtime.kubernetes.namespace
  port             = tonumber(try(var.context.resource.properties.serverSettings.port, "5432"))
  tag              = "16-alpine"
  username         = var.context.resource.properties.username
  password         = var.context.resource.properties.password
  database         = try(var.context.resource.properties.database, "postgres_db")
  size_value       = try(var.context.resource.properties.size, "S")
  extensions       = coalesce(try(var.context.resource.properties.extensions, null), [])
  server_settings  = coalesce(try(var.context.resource.properties.serverSettings, null), {})
  server_args      = flatten([for name, value in local.server_settings : ["-c", "${name}=${value}"]])
  extension_sql    = join("\n", [for name in local.extensions : "CREATE EXTENSION IF NOT EXISTS \"${replace(name, "\"", "\"\"")}\";"])
  init_sql         = try(var.context.resource.properties.initSql, null) == null ? "" : var.context.resource.properties.initSql
  has_init_sql     = trimspace(local.init_sql) != ""
  has_init_scripts = length(local.extensions) > 0 || local.has_init_sql

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }
}

resource "kubernetes_secret" "init_scripts" {
  count = local.has_init_scripts ? 1 : 0

  metadata {
    name      = "${local.resource_name}-extensions"
    namespace = local.namespace
    labels    = local.labels
  }

  data = merge(
    length(local.extensions) > 0 ? { "00-extensions.sql" = local.extension_sql } : {},
    local.has_init_sql ? { "01-init.sql" = local.init_sql } : {}
  )
}

resource "kubernetes_secret" "postgres" {
  metadata {
    name      = "${local.resource_name}-credentials"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    USERNAME = local.username
    PASSWORD = local.password
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
          args  = concat(["postgres"], local.server_args)

          dynamic "volume_mount" {
            for_each = kubernetes_secret.init_scripts
            content {
              name       = "extensions"
              mount_path = "/docker-entrypoint-initdb.d"
              read_only  = true
            }
          }

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
                name = kubernetes_secret.postgres.metadata[0].name
                key  = "USERNAME"
              }
            }
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres.metadata[0].name
                key  = "PASSWORD"
              }
            }
          }

          env {
            name  = "POSTGRES_DB"
            value = local.database
          }
        }
        dynamic "volume" {
          for_each = kubernetes_secret.init_scripts
          content {
            name = "extensions"
            secret {
              secret_name = volume.value.metadata[0].name
            }
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

# The administrator credentials are user-supplied Recipe inputs. They configure
# PostgreSQL through the Kubernetes Secret above but are not returned through
# `result.secrets`.
output "result" {
  value = {
    resources = concat([
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Secret/${kubernetes_secret.postgres.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${local.resource_name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${local.resource_name}"
    ], [for secret in kubernetes_secret.init_scripts : "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Secret/${secret.metadata[0].name}"])
    values = {
      host     = "${kubernetes_service.postgres.metadata[0].name}.${kubernetes_service.postgres.metadata[0].namespace}.svc.cluster.local"
      port     = local.port
      database = local.database
    }
  }
}
