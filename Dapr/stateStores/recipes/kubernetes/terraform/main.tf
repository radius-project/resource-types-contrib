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
  # and a state.redis component that uses it. When the resource sets a type,
  # deploy only the Dapr component from the given type, version, and metadata.
  requested_type    = try(local.properties.componentType, null)
  use_default       = local.requested_type == null || local.requested_type == ""
  dapr_type         = local.use_default ? "state.redis" : local.requested_type
  dapr_version      = try(local.properties.version, null) != null ? local.properties.version : "v1"
  secret_store_name = try(local.properties.auth.secretStore, null) != null ? local.properties.auth.secretStore : ""

  # Never emit an empty list: Dapr treats it as namespace-wide access.
  scope_list        = try(local.properties.scopes, null) != null ? tolist(local.properties.scopes) : var.daprAllowedAppIds
  component_scopes  = { scopes = local.scope_list }
  resource_metadata = try(merge(local.properties.metadata), {})
  invalid_metadata = [
    for name, entry in local.resource_metadata : name if !try(
      trimspace(name) != "" && length(keys(entry)) == 1 &&
      (contains(keys(entry), "value") != contains(keys(entry), "secretKeyRef")) &&
      (contains(keys(entry), "secretKeyRef") ? (
        length(keys(entry.secretKeyRef)) == 2 &&
        trimspace(entry.secretKeyRef.name) != "" && trimspace(entry.secretKeyRef.key) != ""
      ) : entry.value != null), false
    )
  ]
  supported_properties = ["environment", "application", "connections", "codeReference", "recipe", "status", "componentType", "version", "metadata", "auth", "scopes", "componentName"]
  input_errors = compact([
    length(local.scope_list) == 0 ? "Set nonempty scopes or platform daprAllowedAppIds." : "",
    alltrue([for id in local.scope_list : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", id)) && length(id) <= 63]) ? "" : "scopes must contain valid Dapr app IDs of 1 to 63 lowercase letters, digits, or hyphens, with a letter or digit at each end.",
    length(distinct(local.scope_list)) == length(local.scope_list) ? "" : "scopes must not contain duplicate IDs.",
    length(var.daprAllowedAppIds) == 0 || length(setsubtract(local.scope_list, var.daprAllowedAppIds)) == 0 ? "" : "scopes must be a subset of platform daprAllowedAppIds.",
    length(local.invalid_metadata) == 0 ? "" : "Each metadata entry must set exactly one of value or secretKeyRef; secretKeyRef must contain nonempty name and key only.",
    length(setsubtract(keys(local.properties), local.supported_properties)) == 0 ? "" : "Unsupported resource property. Use the Radius.Dapr/stateStores schema.",
    !contains(keys(local.properties), "componentType") || can(regex("^state\\.[^\\s]+$", local.requested_type)) ? "" : "componentType must name a state component, or be omitted for the default.",
    can(regex("^[^\\s]+$", local.dapr_version)) ? "" : "version must be nonempty, or omitted for v1.",
    (try(local.properties.auth, null) == null ? true : try(alltrue([for key in keys(local.properties.auth) : key == "secretStore"]) && (!contains(keys(local.properties.auth), "secretStore") || trimspace(local.secret_store_name) != ""), false)) ? "" : "auth supports only a nonempty secretStore name."
  ])

  redis_name = "daprstate-${substr(sha1(var.context.resource.id), 0, 13)}"
  redis_port = 6379
  redis_host = "${local.redis_name}.${local.namespace}.svc.cluster.local:${local.redis_port}"

  default_metadata = {
    for name, entry in {
      redisHost       = { value = local.redis_host }
      redisPassword   = { value = "" }
      actorStateStore = { value = var.actorStateStore ? "true" : "false" }
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

resource "terraform_data" "validate_inputs" {
  lifecycle {
    precondition {
      condition     = length(local.input_errors) == 0
      error_message = "Invalid Radius.Dapr/stateStores inputs. ${join(" ", local.input_errors)} Fix the inputs and deploy again."
    }
  }
}

# Default Redis state store. A single-replica, non-persistent Redis.
resource "kubernetes_deployment_v1" "redis" {
  count      = local.use_default ? 1 : 0
  depends_on = [terraform_data.validate_inputs]

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
  count      = local.use_default ? 1 : 0
  depends_on = [terraform_data.validate_inputs]

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
    local.component_auth,
    local.component_scopes
  )

  depends_on = [
    terraform_data.validate_inputs,
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
