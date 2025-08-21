terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

resource "kubernetes_persistent_volume" "this" {
  metadata {
    name = var.context.resource.name
    labels = {
      app      = "redis"
      resource = var.context.resource.name
      # Label pods with the application name so `rad run` can find the logs.
      "radapp.io/application" = var.context.application != null ? var.context.application.name : ""
    }
  }

  spec {
    storage_class_name = "manual"
    
    capacity = {
      storage = var.context.resource.properties.size
    }
    
    access_modes = ["ReadWriteOnce"]
    
    persistent_volume_source {
      host_path {
        path = var.host_path
        type = "DirectoryOrCreate"
      }
    }
  }
}