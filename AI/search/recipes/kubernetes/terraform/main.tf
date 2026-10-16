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
  # A unique per-resource name so two search resources that share a display
  # name (or the same name across recreates) never collide on their Kubernetes
  # objects.
  unique_name      = "${local.resource_name}-${substr(sha256(var.context.resource.id), 0, 13)}"
  application_name = var.context.application != null ? var.context.application.name : ""
  environment_name = var.context.environment != null ? var.context.environment.name : ""
  resource_group   = element(split("/", var.context.resource.id), 5)
  namespace        = var.context.runtime.kubernetes.namespace
  port             = 7700
  tag              = "v1.54.3"

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }

  host = "${kubernetes_service.meilisearch.metadata[0].name}.${kubernetes_service.meilisearch.metadata[0].namespace}.svc.cluster.local"
}

# Radius.AI/search has no developer-authored credentials, so the Recipe
# generates the master key. It is kept in the Terraform state, so it stays the
# same across later deployments of the same resource.
resource "random_password" "master_key" {
  length  = 32
  special = false
}

# Stores the master key so the Pod spec references it through secret_key_ref
# instead of carrying it inline.
resource "kubernetes_secret" "master_key" {
  metadata {
    name      = "${local.unique_name}-master-key"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    MEILI_MASTER_KEY = random_password.master_key.result
  }
}

resource "kubernetes_deployment" "meilisearch" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    # A single-replica, non-persistent server. Meilisearch locks its database
    # directory, so Recreate tears the old Pod down before the new one starts
    # instead of briefly running two (the default RollingUpdate).
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
        # A new master key changes the Pod template so the server restarts and
        # reads the updated Secret during deployment.
        annotations = {
          "radapp.io/generated-api-key-hash" = substr(sha256(random_password.master_key.result), 0, 13)
        }
      }

      spec {
        # The Meilisearch server, which serves its REST API on port 7700.
        container {
          name  = "meilisearch"
          image = "getmeili/meilisearch:${local.tag}"

          port {
            name           = "http"
            container_port = local.port
          }

          env {
            # Every request except /health must carry the master key or a key
            # derived from it.
            name = "MEILI_MASTER_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.master_key.metadata[0].name
                key  = "MEILI_MASTER_KEY"
              }
            }
          }

          env {
            # Production mode requires the master key and disables the built-in
            # search preview UI.
            name  = "MEILI_ENV"
            value = "production"
          }

          env {
            name  = "MEILI_NO_ANALYTICS"
            value = "true"
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }

          resources {
            requests = {
              memory = "256Mi"
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/meili_data"
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

resource "kubernetes_service" "meilisearch" {
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
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Secret/${kubernetes_secret.master_key.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${kubernetes_service.meilisearch.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${kubernetes_deployment.meilisearch.metadata[0].name}"
    ]
    values = {
      endpoint = "http://${local.host}:${local.port}"
    }
    secrets = {
      # The master key. Radius materializes it into the managed
      # Radius.Security/secrets resource; it is never written onto the resource.
      apiKey = random_password.master_key.result
    }
  }
  sensitive = true
}
