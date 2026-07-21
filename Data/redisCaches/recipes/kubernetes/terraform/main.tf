terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
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

# In-cluster Redis Deployment. Runs without authentication (no requirepass),
# matching the default local-dev Redis recipe for a quick-start experience.
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
          # first arg starts with '-'. --maxmemory caps the dataset (below the
          # memory request) and allkeys-lru evicts keys under pressure instead of
          # OOM-killing the pod.
          args = ["--maxmemory", var.memory[local.size_value].maxmemory, "--maxmemory-policy", "allkeys-lru"]

          port {
            container_port = local.port
          }

          resources {
            requests = {
              memory = var.memory[local.size_value].memoryRequest
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
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${kubernetes_service.redis.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${kubernetes_deployment.redis.metadata[0].name}"
    ]
    values = {
      host = local.host
      port = local.port
    }
    secrets = {
      # In-cluster Redis runs without auth (no TLS, no password), so the URL is a
      # plain redis://host:port. Radius still materializes it into the managed
      # Radius.Security/secrets resource; it is never written onto the resource.
      url = "redis://${local.host}:${local.port}"
    }
  }
  sensitive = true
}
