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
  port             = 5432
  tag              = "16-alpine"
  username         = var.context.resource.properties.username
  password         = var.context.resource.properties.password
  database         = try(var.context.resource.properties.database, "postgres_db")
  size_value       = try(var.context.resource.properties.size, "S")
  tls              = coalesce(try(var.context.resource.properties.tls, null), "required")

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
    progress_deadline_seconds = 120
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
          command = ["/bin/sh", "-ec", <<-EOT
            case "$RADIUS_TLS" in
              required) plaintext_auth=reject ;;
              optional) plaintext_auth=scram-sha-256 ;;
              *) echo "Error: PostgreSQL tls must be required or optional." >&2; exit 1 ;;
            esac
            if [ ! -s /tls-source/tls.crt ] || [ ! -s /tls-source/tls.key ]; then
              echo "Error: Create Kubernetes TLS Secret $RADIUS_TLS_SECRET with tls.crt and tls.key in this namespace." >&2
              exit 1
            fi
            umask 077
            # Remove emptyDir's sticky mode so root can refresh postgres-owned files on restart.
            chmod 0755 /tls-runtime
            cp /tls-source/tls.crt /tls-runtime/server.crt
            cp /tls-source/tls.key /tls-runtime/server.key
            printf 'local all all trust\nhostnossl all all 0.0.0.0/0 %s\nhostnossl all all ::/0 %s\nhostssl all all 0.0.0.0/0 scram-sha-256\nhostssl all all ::/0 scram-sha-256\n' "$plaintext_auth" "$plaintext_auth" > /tls-runtime/pg_hba.conf
            chown postgres:postgres /tls-runtime/server.crt /tls-runtime/server.key /tls-runtime/pg_hba.conf
            chmod 0600 /tls-runtime/server.key
            exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tls-runtime/server.crt -c ssl_key_file=/tls-runtime/server.key -c hba_file=/tls-runtime/pg_hba.conf
          EOT
          ]

          readiness_probe {
            exec {
              command = ["/bin/sh", "-ec", "PGPASSWORD=\"$POSTGRES_PASSWORD\" PGSSLMODE=require PGCONNECT_TIMEOUT=3 psql -X -w -h 127.0.0.1 -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -Atc \"SELECT 1\""]
            }
            timeout_seconds = 5
            period_seconds  = 5
          }

          env {
            name  = "RADIUS_TLS"
            value = local.tls
          }

          env {
            name  = "RADIUS_TLS_SECRET"
            value = "${local.resource_name}-tls"
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

          volume_mount {
            name       = "tls-source"
            mount_path = "/tls-source"
            read_only  = true
          }

          volume_mount {
            name       = "tls-runtime"
            mount_path = "/tls-runtime"
          }
        }

        volume {
          name = "tls-source"
          secret {
            secret_name  = "${local.resource_name}-tls"
            optional     = true
            default_mode = "0400"
          }
        }

        volume {
          name = "tls-runtime"
          empty_dir {
            medium = "Memory"
          }
        }
      }

    }
  }

  timeouts {
    create = "3m"
    update = "3m"
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
