terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
  }
}

resource "kubernetes_deployment" "redis" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = var.tags
  }

  spec {
    selector {
      match_labels = var.tags
    }

    template {
      metadata {
        labels = var.tags
      }

      spec {
        container {
          name  = "redis"
          image = "redis:${var.redis_image_tag}"

          port {
            container_port = var.redis_port
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = var.tags
  }

  spec {
    selector = var.tags

    port {
      port = var.redis_port
    }

    type = "ClusterIP"
  }
}
