terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
  }
}
locals {
  namespace         = var.context.runtime.kubernetes.namespace
  resource_name     = var.context.resource.name
  application_name  = var.context.application != null ? var.context.application.name : ""
  environment_id    = try(var.context.resource.properties.environment, "")
  environment_parts = local.environment_id != "" ? split("/", local.environment_id) : []
  environment_label = length(local.environment_parts) > 0 ? local.environment_parts[length(local.environment_parts) - 1] : ""
}

resource "kubernetes_persistent_volume_claim" "pvc" {
  wait_until_bound = false

  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels = {
      "radapp.io/resource"    = local.resource_name
      "radapp.io/application" = local.application_name
      "radapp.io/environment" = local.environment_label
    }
  }

  spec {
    storage_class_name = var.storage_class != "" ? var.storage_class : null

    resources {
      requests = {
        storage = format("%dGi", var.context.resource.properties.sizeInGib)
      }
    }

    access_modes = can(var.context.resource.properties.allowedAccessModes) ? [var.context.resource.properties.allowedAccessModes] : ["ReadWriteOnce"]
  }
}

output "result" {
  value = {
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/PersistentVolumeClaim/${local.resource_name}"
    ]
    values = {
      claimName = local.resource_name
    }
  }
}