terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}

locals {
  resource_name    = var.context.resource.name
  application_name = var.context.application != null ? var.context.application.name : ""
  environment_name = var.context.environment != null ? var.context.environment.name : ""
  resource_group   = element(split("/", var.context.resource.id), 5)
  namespace        = var.context.runtime.kubernetes.namespace
  port             = 27017
  # MongoDB 8.0 and later refuse to start on Linux kernel 6.19 and newer
  # (https://jira.mongodb.org/browse/SERVER-121912), which recent cluster nodes
  # already run. 7.0 starts on every kernel.
  tag            = "7.0"
  username       = "admin"
  database_input = try(var.context.resource.properties.database, null)
  database       = local.database_input != null ? local.database_input : "mongo_db"

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }

  host = "${local.resource_name}.${local.namespace}.svc.cluster.local"
}

# The resource type has no credential properties, so the Recipe generates the
# administrator password itself and returns it inside
# `secrets.connectionString`. The value is kept in the Terraform state, so it
# stays the same when the Recipe runs again.
resource "random_password" "password" {
  length  = 32
  special = false
}

# Store the credentials in a Kubernetes Secret so the MongoDB container reads
# them through secretKeyRef rather than carrying the password inline in the
# Pod spec.
resource "kubernetes_secret" "mongo" {
  metadata {
    name      = "${local.resource_name}-credentials"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    USERNAME = local.username
    PASSWORD = random_password.password.result
  }
}

# In-cluster MongoDB Deployment with authentication enabled.
resource "kubernetes_deployment" "mongo" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    # Single-replica, non-persistent database: Recreate tears down the old Pod
    # before starting the new one on update, so two divergent MongoDB servers
    # never back the same Service at once (default RollingUpdate would run both).
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
          # A new password changes the Pod template, so MongoDB restarts on a
          # fresh data volume and creates the administrator with the password
          # now in the Secret and the connection string.
          "radapp.io/generated-password-hash" = substr(sha256(random_password.password.result), 0, 13)
        }
      }

      spec {
        container {
          # The image entrypoint creates the administrator in the `admin`
          # database from the MONGO_INITDB_ROOT_* variables on first start and
          # then enables authentication. It prepends `mongod` when the first arg
          # starts with '-'. The WiredTiger cache is capped so the server stays
          # well within the memory request instead of sizing itself from the node.
          name  = "mongo"
          image = "mongo:${local.tag}"
          args  = ["--wiredTigerCacheSizeGB", "0.25"]

          port {
            name           = "mongodb"
            container_port = local.port
          }

          env {
            name = "MONGO_INITDB_ROOT_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mongo.metadata[0].name
                key  = "USERNAME"
              }
            }
          }

          env {
            name = "MONGO_INITDB_ROOT_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mongo.metadata[0].name
                key  = "PASSWORD"
              }
            }
          }

          # While the entrypoint creates the administrator, it runs a temporary
          # server bound to 127.0.0.1 only. The port on the Pod IP opens only
          # once the final server is up with authentication on.
          readiness_probe {
            tcp_socket {
              port = "mongodb"
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          resources {
            requests = {
              memory = "512Mi"
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data/db"
          }
        }

        volume {
          name = "data"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "mongo" {
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
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Secret/${kubernetes_secret.mongo.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${kubernetes_service.mongo.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${kubernetes_deployment.mongo.metadata[0].name}"
    ]
    values = {
      endpoint = "${local.host}:${local.port}"
      database = local.database
    }
    secrets = {
      # The administrator is created in the `admin` database, so the connection
      # string sets authSource=admin and selects `database` as the default
      # database. Radius materializes it into the managed Radius.Security/secrets
      # resource; it is never written onto the resource.
      connectionString = "mongodb://${local.username}:${random_password.password.result}@${local.host}:${local.port}/${local.database}?authSource=admin"
    }
  }
  sensitive = true
}
