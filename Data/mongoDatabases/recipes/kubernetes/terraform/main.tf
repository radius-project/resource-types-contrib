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
  resource_name = var.context.resource.name
  namespace     = var.context.runtime.kubernetes.namespace
  database      = coalesce(try(var.context.resource.properties.database, null), "mongo_db")
  username      = "radius"
  port          = 27017
  password      = var.mongoCredentialsSecretName != null ? data.kubernetes_secret_v1.credentials[0].data.password : random_password.mongo[0].result
  secret_name   = var.mongoCredentialsSecretName != null ? var.mongoCredentialsSecretName : kubernetes_secret_v1.credentials[0].metadata[0].name
  probe         = "const admin = db.getSiblingDB(\"admin\"); if (!admin.auth(process.env.MONGO_INITDB_ROOT_USERNAME, process.env.MONGO_INITDB_ROOT_PASSWORD).ok) { quit(1); } quit(admin.runCommand({ping: 1}).ok ? 0 : 1);"
  endpoint      = "mongodb://${kubernetes_service_v1.mongo.metadata[0].name}.${local.namespace}.svc.cluster.local:${local.port}"

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = try(var.context.application.name, "")
    "radapp.io/environment"    = try(var.context.environment.name, "")
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = split("/", var.context.resource.id)[5]
  }
  selector = {
    "radapp.io/resource"  = local.resource_name
    "radapp.io/component" = "mongodb"
  }
}

resource "random_password" "mongo" {
  count   = var.mongoCredentialsSecretName == null ? 1 : 0
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "credentials" {
  count = var.mongoCredentialsSecretName == null ? 1 : 0

  metadata {
    name      = "${local.resource_name}-mongodb-credentials"
    namespace = local.namespace
    labels    = local.labels
  }
  type = "Opaque"
  data = {
    password = local.password
  }
}

data "kubernetes_secret_v1" "credentials" {
  count = var.mongoCredentialsSecretName != null ? 1 : 0

  metadata {
    name      = var.mongoCredentialsSecretName
    namespace = local.namespace
  }
}

resource "kubernetes_persistent_volume_claim_v1" "data" {
  metadata {
    name      = "${local.resource_name}-mongodb-data"
    namespace = local.namespace
    labels    = local.labels
  }
  # A WaitForFirstConsumer StorageClass binds only after the Pod is scheduled.
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment_v1" "mongo" {
  metadata {
    name      = "${local.resource_name}-mongodb"
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = local.selector
    }
    template {
      metadata {
        labels = merge(local.labels, local.selector)
      }
      spec {
        automount_service_account_token = false
        security_context {
          run_as_user  = 999
          run_as_group = 999
          fs_group     = 999
        }
        container {
          name  = "mongodb"
          image = "mongo:8.0"
          port {
            container_port = local.port
          }
          env {
            name  = "MONGO_INITDB_ROOT_USERNAME"
            value = local.username
          }
          env {
            name = "MONGO_INITDB_ROOT_PASSWORD"
            value_from {
              secret_key_ref {
                name = local.secret_name
                key  = "password"
              }
            }
          }
          env {
            name  = "MONGO_INITDB_DATABASE"
            value = local.database
          }
          volume_mount {
            name       = "data"
            mount_path = "/data/db"
          }
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
          startup_probe {
            exec {
              command = ["mongosh", "--quiet", "--eval", local.probe]
            }
            period_seconds    = 5
            failure_threshold = 60
            timeout_seconds   = 5
          }
          readiness_probe {
            exec {
              command = ["mongosh", "--quiet", "--eval", local.probe]
            }
            period_seconds  = 10
            timeout_seconds = 5
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "mongo" {
  metadata {
    name      = "${local.resource_name}-mongodb"
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    type     = "ClusterIP"
    selector = local.selector
    port {
      port        = local.port
      target_port = local.port
    }
  }
}

output "result" {
  value = {
    resources = concat(
      [for secret in kubernetes_secret_v1.credentials : "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Secret/${secret.metadata[0].name}"],
      [
        "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/PersistentVolumeClaim/${kubernetes_persistent_volume_claim_v1.data.metadata[0].name}",
        "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${kubernetes_deployment_v1.mongo.metadata[0].name}",
        "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${kubernetes_service_v1.mongo.metadata[0].name}"
      ]
    )
    values = {
      database = local.database
      endpoint = local.endpoint
    }
    secrets = {
      connectionString = "mongodb://${local.username}:${replace(urlencode(local.password), "+", "%20")}@${kubernetes_service_v1.mongo.metadata[0].name}.${local.namespace}.svc.cluster.local:${local.port}/${replace(urlencode(local.database), "+", "%20")}?authSource=admin"
    }
  }
  sensitive = true
}
