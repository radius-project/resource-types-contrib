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

variable "postgresqlTlsSecretName" {
  description = "Operator-owned TLS Secret in the runtime namespace. Defaults to <resource-name>-tls; ignored for disabled policy."
  type        = string
  default     = null
}

variable "postgresqlTlsCertificateRevision" {
  description = "Non-secret revision that triggers rollout when a TLS-enabled database is redeployed. Protect ephemeral data first."
  type        = string
  default     = ""
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
  port             = 5432
  tag              = "16-alpine"
  username         = var.context.resource.properties.username
  password         = var.context.resource.properties.password
  database         = try(var.context.resource.properties.database, "postgres_db")
  size_value       = try(var.context.resource.properties.size, "S")
  tls_policy       = coalesce(try(var.context.resource.properties.tls, null), "required")
  tls_secret_name  = coalesce(var.postgresqlTlsSecretName, "${local.resource_name}-tls")
  tls_enabled = {
    required = true
    optional = true
    disabled = false
  }[local.tls_policy]

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }
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
        annotations = local.tls_enabled ? {
          "radapp.io/tls-certificate-revision" = var.postgresqlTlsCertificateRevision
        } : {}
      }

      spec {
        container {
          name    = "postgres"
          image   = "postgres:${local.tag}"
          command = ["/bin/sh", "-ec"]
          args    = [file("${path.module}/configure-postgresql.sh")]

          port {
            container_port = local.port
          }

          readiness_probe {
            exec {
              command = ["/bin/sh", "-ec", "pg_isready -h 127.0.0.1 -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
            }
            period_seconds  = 5
            timeout_seconds = 5
          }

          resources {
            requests = {
              memory = var.memory[local.size_value].memoryRequest
            }
          }

          env {
            name  = "POSTGRES_TLS"
            value = local.tls_policy
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

          volume_mount {
            name       = "postgres-config"
            mount_path = "/postgres-config"
          }

          dynamic "volume_mount" {
            for_each = local.tls_enabled ? [1] : []
            content {
              name       = "tls-source"
              mount_path = "/tls-source"
              read_only  = true
            }
          }
        }

        volume {
          name = "postgres-config"
          empty_dir {
            medium = "Memory"
          }
        }

        dynamic "volume" {
          for_each = local.tls_enabled ? [1] : []
          content {
            name = "tls-source"
            secret {
              secret_name  = local.tls_secret_name
              default_mode = "0400"
              items {
                key  = "tls.crt"
                path = "tls.crt"
              }
              items {
                key  = "tls.key"
                path = "tls.key"
              }
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
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Secret/${kubernetes_secret.postgres.metadata[0].name}",
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
