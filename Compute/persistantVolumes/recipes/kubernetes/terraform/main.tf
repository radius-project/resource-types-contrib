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

resource "kubernetes_persistent_volume" "pv" {
  metadata {
    name = var.context.resource.name
    labels = {
      resource = var.context.resource.name
      # Label pods with the application name so `rad run` can find the logs.
      "radapp.io/application" = var.context.application != null ? var.context.application.name : ""
    }
  }

  spec {
    storage_class_name = var.storage_class

    capacity = {
      storage = var.context.resource.properties.sizeInGib
    }

    access_modes = can(var.context.resource.properties.allowedAccessModes) ? [var.context.resource.properties.allowedAccessModes] : ["ReadWriteOnce", "ReadOnlyMany", "ReadWriteMany"]

    persistent_volume_source {
      csi {
        driver        = var.csi_driver
        volume_handle = var.csi_volume_handle
      }
    }
  }
}

output "result" {
  value = {
    resources = [
      "/planes/kubernetes/local/providers/core/PersistentVolume/${var.context.resource.name}"
    ]
  }
}