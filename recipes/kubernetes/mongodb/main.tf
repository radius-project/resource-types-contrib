provider "kubernetes" {
  config_path = "~/.kube/config"
}

# Secret for credentials
resource "kubernetes_secret" "mongodb_credentials" {
  metadata {
    name      = "${var.name}-credentials"
    namespace = "default"
  }
  data = {
    username = base64encode(var.username)
    password = base64encode(var.password)
  }
}

# Persistent Volume Claim (if persistence enabled)
resource "kubernetes_persistent_volume_claim" "mongodb" {
  count = var.persistence ? 1 : 0

  metadata {
    name      = "${var.name}-pvc"
    namespace = "default"
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = var.storage_size
      }
    }
    storage_class_name = var.storage_class
  }
}

# Service
resource "kubernetes_service" "mongodb" {
  metadata {
    name      = "${var.name}-svc"
    namespace = "default"
  }

  spec {
    selector = {
      app = var.name
    }
    port {
      port        = 27017
      target_port = 27017
    }
    type = "ClusterIP"
  }
}

# StatefulSet
resource "kubernetes_stateful_set" "mongodb" {
  metadata {
    name      = var.name
    namespace = "default"
    labels = {
      app = var.name
    }
  }

  spec {
    service_name = "${var.name}-svc"
    replicas     = var.replicas

    selector {
      match_labels = {
        app = var.name
      }
    }

    template {
      metadata {
        labels = {
          app = var.name
        }
      }

      spec {
        container {
          name  = "mongodb"
          image = "mongo:${var.mongodb_version}"

          port {
            container_port = 27017
          }

          env {
            name  = "MONGO_INITDB_ROOT_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mongodb_credentials.metadata[0].name
                key  = "username"
              }
            }
          }

          env {
            name  = "MONGO_INITDB_ROOT_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mongodb_credentials.metadata[0].name
                key  = "password"
              }
            }
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          dynamic "volume_mount" {
            for_each = var.persistence ? [1] : []
            content {
              name       = "data"
              mount_path = "/data/db"
            }
          }
        }
        dynamic "volume" {
          for_each = var.persistence ? [1] : []
          content {
            name = "data"

            persistent_volume_claim {
              claim_name = kubernetes_persistent_volume_claim.mongodb[0].metadata[0].name
            }
          }
        }
      }
    }
  }

  timeouts {
    create = "40m"
  }
}
