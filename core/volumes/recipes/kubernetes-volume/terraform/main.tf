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
      storage = var.context.resource.properties.size
    }

    access_modes = [var.access_mode]

    persistent_volume_source {
      host_path {
        path = var.host_path
        type = "DirectoryOrCreate"
      }
    }
  }
}

output "result" {
  value = {
    resources = [
      "/planes/kubernetes/local/providers/core/PersistentVolume/${var.context.resource.name}"
    ]
    values = {
      kind         = "persistent"
      storage_class_name = var.storage_class
      capacity         = var.context.resource.properties.size      
      access_modes = var.access_mode
      host_path    = var.host_path
    }
  }
}