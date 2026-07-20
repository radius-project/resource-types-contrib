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
  port             = 6379
  tag              = "7-alpine"
  size_value       = try(var.context.resource.properties.size, "S")

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }

  host = "${local.resource_name}.${local.namespace}.svc.cluster.local"
}

# The Radius.Data/redisCaches resource exposes no credential property: it is
# designed so the platform generates its own access key. This recipe generates
# one. random_password is persisted in Terraform state, keeping it stable and
# idempotent across applies.
resource "random_password" "redis" {
  length  = 24
  special = false
}

# Store the generated password in a Kubernetes Secret so the Redis container
# references it via secretKeyRef rather than carrying it inline in the Pod spec.
resource "kubernetes_secret" "redis" {
  metadata {
    name      = "${local.resource_name}-credentials"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    REDIS_PASSWORD = random_password.redis.result
  }
}

resource "kubernetes_deployment" "redis" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    # Single-replica, non-persistent cache: Recreate tears down the old Pod
    # before starting the new one on update, so two divergent Redis instances
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
      }

      spec {
        container {
          name  = "redis"
          image = "redis:${local.tag}"

          # The default redis image entrypoint prepends `redis-server` when the
          # first arg starts with '-'. Kubernetes substitutes $(REDIS_PASSWORD)
          # from the env var below (sourced from the Secret) at runtime.
          # --maxmemory caps the dataset (below the memory request) and
          # allkeys-lru evicts keys under pressure instead of OOM-killing the pod.
          args = ["--requirepass", "$(REDIS_PASSWORD)", "--maxmemory", var.memory[local.size_value].maxmemory, "--maxmemory-policy", "allkeys-lru"]

          port {
            container_port = local.port
          }

          resources {
            requests = {
              memory = var.memory[local.size_value].memoryRequest
            }
          }

          env {
            name = "REDIS_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.redis.metadata[0].name
                key  = "REDIS_PASSWORD"
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
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
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Secret/${kubernetes_secret.redis.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${kubernetes_service.redis.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${kubernetes_deployment.redis.metadata[0].name}"
    ]
    values = {
      host = local.host
      port = local.port
    }
    secrets = {
      # In-cluster Redis is reached over plaintext (no TLS), so the scheme is
      # `redis://` (not `rediss://`). Radius materializes this into the managed
      # Radius.Security/secrets resource; it is never written onto the resource.
      url = "redis://:${random_password.redis.result}@${local.host}:${local.port}"
    }
  }
  sensitive = true
}
