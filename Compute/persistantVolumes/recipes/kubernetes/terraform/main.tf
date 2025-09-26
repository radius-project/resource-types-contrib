terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
  }
}
locals {
  uniqueName = var.context.resource.name
  namespace = var.context.runtime.kubernetes.namespace
}

resource "kubernetes_persistent_volume_claim" "pvc" {
  wait_until_bound = false
  
  metadata {
    name      = var.context.resource.name
    namespace = local.namespace
    labels = {
      resource = var.context.resource.name
      # Label pods with the application name so `rad run` can find the logs.
      "radapp.io/application" = var.context.application != null ? var.context.application.name : ""
    }
  }

  spec {
    storage_class_name = var.storage_class != "" ? var.storage_class : null

    resources {
      requests = {
        storage = var.context.resource.properties.sizeInGib
      }
    }

    access_modes = can(var.context.resource.properties.allowedAccessModes) ? [var.context.resource.properties.allowedAccessModes] : ["ReadWriteOnce", "ReadOnlyMany", "ReadWriteMany"]
  }
}

output "result" {
  value = {
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/PersistentVolumeClaim/${var.context.resource.name}"
    ]
  }
}