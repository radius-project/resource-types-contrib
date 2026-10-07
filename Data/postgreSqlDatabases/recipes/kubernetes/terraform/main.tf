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

  validation {
    # Keep this default in sync with local.tls_policy; Terraform 1.5 validation cannot reference locals.
    condition     = contains(["required", "optional"], try(var.context.resource.properties.tls, null) == null ? "required" : var.context.resource.properties.tls)
    error_message = "PostgreSQL tls must be required or optional."
  }
}

variable "postgresqlTlsSecretName" {
  description = "Operator-owned Kubernetes TLS Secret in the database namespace, containing tls.crt and tls.key. Empty selects <resource-name>-tls; the certificate must cover the Service hostname."
  type        = string
  default     = ""
  nullable    = false
}

variable "postgresqlTlsCertificateRevision" {
  description = "Change this value after replacing the TLS Secret to roll out the new certificate. Back up data before rolling out this ephemeral database."
  type        = string
  default     = "1"
  nullable    = false

  validation {
    condition     = length(var.postgresqlTlsCertificateRevision) > 0
    error_message = "postgresqlTlsCertificateRevision must not be empty."
  }
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
  tls_policy       = try(var.context.resource.properties.tls, null) == null ? "required" : var.context.resource.properties.tls
  tls_secret_name  = coalesce(var.postgresqlTlsSecretName, "${local.resource_name}-tls")
  # Keep Unix-socket initialization available; no broad host rule may bypass TLS.
  hba_required_config = <<-EOT
    local all all trust
    hostnossl all all 0.0.0.0/0 reject
    hostnossl all all ::/0 reject
    hostssl all all 0.0.0.0/0 scram-sha-256
    hostssl all all ::/0 scram-sha-256
  EOT
  hba_optional_config = replace(local.hba_required_config, " reject", " scram-sha-256")

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }
}

resource "kubernetes_config_map" "transport" {
  metadata {
    name      = "${local.resource_name}-transport"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    # Both files are stable across policy transitions; selection happens in args.
    "pg_hba-required.conf" = local.hba_required_config
    "pg_hba-optional.conf" = local.hba_optional_config
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
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "radapp.io/resource" = local.resource_name
      }
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          "radapp.io/postgresql-tls-policy"   = local.tls_policy
          "radapp.io/postgresql-tls-revision" = var.postgresqlTlsCertificateRevision
        }
      }

      spec {
        init_container {
          name  = "prepare-tls"
          image = "postgres:${local.tag}"
          command = ["/bin/sh", "-ec", <<-EOT
            test -s /tls-source/tls.crt && test -s /tls-source/tls.key || {
              echo "PostgreSQL requires a TLS Secret with nonempty tls.crt and tls.key" >&2
              exit 1
            }
            cp /tls-source/tls.crt /tls/server.crt
            cp /tls-source/tls.key /tls/server.key
            chown -R postgres:postgres /tls
            chmod 700 /tls
            chmod 600 /tls/server.key
            chmod 644 /tls/server.crt
          EOT
          ]

          security_context {
            run_as_user = 0
          }

          volume_mount {
            name       = "tls-source"
            mount_path = "/tls-source"
            read_only  = true
          }

          volume_mount {
            name       = "tls"
            mount_path = "/tls"
          }
        }

        container {
          name  = "postgres"
          image = "postgres:${local.tag}"
          args = [
            "postgres",
            "-c", "ssl=on",
            "-c", "ssl_min_protocol_version=TLSv1.2",
            "-c", "ssl_cert_file=/tls/server.crt",
            "-c", "ssl_key_file=/tls/server.key",
            "-c", "hba_file=/transport/pg_hba-${local.tls_policy}.conf",
            "-c", "password_encryption=scram-sha-256",
          ]

          readiness_probe {
            exec {
              command = ["pg_isready", "-q", "-h", "127.0.0.1"]
            }
            period_seconds  = 5
            timeout_seconds = 3
          }

          volume_mount {
            name       = "tls"
            mount_path = "/tls"
            read_only  = true
          }

          volume_mount {
            name       = "transport"
            mount_path = "/transport"
            read_only  = true
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

        volume {
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

        volume {
          name = "tls"
          empty_dir {
            medium = "Memory"
          }
        }

        volume {
          name = "transport"
          config_map {
            name = kubernetes_config_map.transport.metadata[0].name
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
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/ConfigMap/${kubernetes_config_map.transport.metadata[0].name}",
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
