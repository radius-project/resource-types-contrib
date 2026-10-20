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
  properties       = var.context.resource.properties

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }

  # When the resource does not set a component type, deploy a Redis instance
  # and a pubsub.redis component that uses it. When the resource sets a type,
  # deploy only the Dapr component from the given type, version, and metadata.
  requested_type    = try(local.properties.type, null)
  use_default       = local.requested_type == null || local.requested_type == ""
  dapr_type         = local.use_default ? "pubsub.redis" : local.requested_type
  dapr_version      = try(local.properties.version, null) != null ? local.properties.version : "v1"
  secret_store_name = try(local.properties.auth.secretStore, null) != null ? local.properties.auth.secretStore : ""

  redis_name = "daprpubsub-${substr(sha1(var.context.resource.id), 0, 13)}"
  redis_port = 6379
  redis_host = "${local.redis_name}.${local.namespace}.svc.cluster.local:${local.redis_port}"

  default_metadata = {
    for name, entry in {
      redisHost     = { value = local.redis_host }
      redisPassword = { value = "" }
    } : name => entry if local.use_default
  }

  # Entries from the resource override the default entries.
  merged_metadata = try(merge(local.default_metadata, local.properties.metadata), local.default_metadata)
  component_metadata = [
    for name, entry in local.merged_metadata : merge({ name = name }, entry)
  ]

  # Dapr defines `auth` at the Component root, next to `spec`. When `auth` is
  # present, `auth.secretStore` is required, so omit `auth` when it is empty.
  component_auth = {
    for key, value in { auth = { secretStore = local.secret_store_name } } : key => value
    if local.secret_store_name != ""
  }

  component_spec = {
    type     = local.dapr_type
    version  = local.dapr_version
    metadata = local.component_metadata
  }
}

# Default Redis pub/sub broker. A single-replica, non-persistent Redis.
resource "kubernetes_deployment_v1" "redis" {
  count = local.use_default ? 1 : 0

  metadata {
    name      = local.redis_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    # Recreate stops the old Pod before the new Pod starts, so two Redis
    # instances never serve the same Service.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "app.kubernetes.io/instance" = local.redis_name
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "dapr-redis"
          "app.kubernetes.io/instance" = local.redis_name
          "radapp.io/application"      = local.application_name
        }
      }

      spec {
        container {
          name  = "redis"
          image = "redis:${var.redisImageTag}"

          port {
            container_port = local.redis_port
          }

          resources {
            requests = {
              memory = var.redisMemoryRequest
            }
            limits = {
              memory = var.redisMemoryLimit
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "redis" {
  count = local.use_default ? 1 : 0

  metadata {
    name      = local.redis_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    type = "ClusterIP"

    selector = {
      "app.kubernetes.io/instance" = local.redis_name
    }

    port {
      port = local.redis_port
    }
  }
}

resource "kubernetes_manifest" "dapr_component" {
  manifest = merge(
    {
      apiVersion = "dapr.io/v1alpha1"
      kind       = "Component"
      metadata = {
        name      = local.resource_name
        namespace = local.namespace
        labels    = local.labels
      }
      spec = local.component_spec
    },
    local.component_auth
  )

  depends_on = [
    kubernetes_deployment_v1.redis,
    kubernetes_service_v1.redis
  ]
}

output "result" {
  value = {
    resources = concat(
      ["/planes/kubernetes/local/namespaces/${local.namespace}/providers/dapr.io/Component/${local.resource_name}"],
      local.use_default ? [
        "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${local.redis_name}",
        "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${local.redis_name}"
      ] : []
    )
    values = {
      componentName = kubernetes_manifest.dapr_component.manifest.metadata.name
      version       = local.dapr_version
    }
  }
}
