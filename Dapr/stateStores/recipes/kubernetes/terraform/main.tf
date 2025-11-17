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
  # Recipes inputs (doesn't use variables directly)
  inputs       = var.context.resource.properties
  default_type = "state.redis"
  type         = try(local.inputs.type, local.default_type)
  version      = try(local.inputs.version, "v1")
  metadata     = try(local.inputs.metadata, [])
  secretStore  = try(local.inputs.secretStore, "")

  # Env context
  namespace        = var.context.runtime.kubernetes.namespace
  application_name = try(var.context.application.name, "")

  # Computed values
  resource_name = "daprstate-${substr(md5(var.context.resource.id), 0, 13)}"
  radius_tags = {
    resource = var.context.resource.name
    // To Review : Are the two of them necessary?
    app                     = local.application_name
    "radapp.io/application" = local.application_name
  }
  computed_metadata = concat(try(module.default_state_store[0].metadata, []), local.metadata)

  # Output values
  dapr_component_id = "/planes/kubernetes/local/namespaces/${local.namespace}/providers/dapr.io/Component/${local.resource_name}"
  resource_ids      = concat([local.dapr_component_id], try(module.default_state_store[0].resource_ids, []))
}

module "default_state_store" {
  source = "./modules/redis"
  count  = local.type == local.default_type ? 1 : 0

  name      = local.resource_name
  namespace = local.namespace
  tags      = local.radius_tags
}

resource "kubernetes_manifest" "dapr_component" {
  manifest = {
    apiVersion = "dapr.io/v1alpha1"
    kind       = "Component"
    metadata = {
      name      = local.resource_name
      namespace = local.namespace
      labels    = local.radius_tags
    }
    auth = {
      secretStore = local.secretStore
    }
    spec = {
      type    = local.type
      version = local.version
      metadata = [
        for entry in local.computed_metadata : merge(
          { name = entry.name },
          try(entry.value, null) != null ? { value = entry.value } : {},
          try(entry.secretKeyRef, null) != null ? { secretKeyRef = entry.secretKeyRef } : {}
        )
      ]
    }
  }
}

output "result" {
  value = {
    resources = local.resource_ids
    values = {
      type          = local.type
      componentName = local.resource_name
    }
  }
}
