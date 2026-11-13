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
  application_name = try(var.context.application.name, "")
  environment_name = try(var.context.environment.name, "")
  resource_group   = element(split("/", var.context.resource.id), 5)
  namespace        = var.context.runtime.kubernetes.namespace
  port             = 3306
  username         = var.context.resource.properties.username
  password         = var.context.resource.properties.password
  database         = coalesce(try(var.context.resource.properties.database, null), "mysql_db")
  version          = coalesce(try(var.context.resource.properties.version, null), "8.4")
  tls              = coalesce(try(var.context.resource.properties.tls, null), "required")

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }
}

resource "kubernetes_secret_v1" "mysql" {
  metadata {
    name      = "${local.resource_name}-credentials"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    USERNAME = local.username
    PASSWORD = local.password
  }
}

resource "kubernetes_deployment_v1" "mysql" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    selector {
      match_labels = {
        "radapp.io/resource" = local.resource_name
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        container {
          name  = "mysql"
          image = "mysql:${local.version}"
          args  = [local.tls == "optional" ? "--require-secure-transport=OFF" : "--require-secure-transport=ON"]

          port {
            container_port = local.port
          }

          env {
            name  = "MYSQL_RANDOM_ROOT_PASSWORD"
            value = "yes"
          }

          env {
            name = "MYSQL_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mysql.metadata[0].name
                key  = "USERNAME"
              }
            }
          }

          env {
            name = "MYSQL_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mysql.metadata[0].name
                key  = "PASSWORD"
              }
            }
          }

          env {
            name  = "MYSQL_DATABASE"
            value = local.database
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "mysql" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    type = "ClusterIP"
    selector = {
      "radapp.io/resource" = local.resource_name
    }
    port {
      port = local.port
    }
  }
}

# Credentials are developer-owned inputs, not managed Recipe outputs.
output "result" {
  value = {
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Secret/${kubernetes_secret_v1.mysql.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${kubernetes_service_v1.mysql.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${kubernetes_deployment_v1.mysql.metadata[0].name}"
    ]
    values = {
      host     = "${kubernetes_service_v1.mysql.metadata[0].name}.${kubernetes_service_v1.mysql.metadata[0].namespace}.svc.cluster.local"
      port     = local.port
      database = local.database
    }
  }
}
