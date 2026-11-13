terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}

locals {
  resource_name     = var.context.resource.name
  unique_name       = "${local.resource_name}-${substr(sha256(var.context.resource.id), 0, 13)}"
  application_name  = var.context.application != null ? var.context.application.name : ""
  environment_name  = var.context.environment != null ? var.context.environment.name : ""
  namespace         = var.context.runtime.kubernetes.namespace
  username          = try(var.context.resource.properties.username, null) == null ? "radius" : var.context.resource.properties.username
  queue             = try(var.context.resource.properties.queue, null) == null ? "jobs" : var.context.resource.properties.queue
  password_id       = try(var.context.resource.properties.password, null) == null ? "" : var.context.resource.properties.password
  supplied_password = local.password_id != ""
  credentials_name  = local.supplied_password ? element(reverse(split("/", local.password_id)), 0) : kubernetes_secret_v1.credentials[0].metadata[0].name
  port              = 5672
  image             = "rabbitmq:4-alpine"
  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = element(split("/", var.context.resource.id), 5)
  }
  definitions = {
    users = [{
      name              = local.username
      password_hash     = ""
      hashing_algorithm = "rabbit_password_hashing_sha256"
      tags              = ["administrator"]
    }]
    vhosts      = [{ name = "/" }]
    permissions = [{ user = local.username, vhost = "/", configure = ".*", write = ".*", read = ".*" }]
    queues      = [{ name = local.queue, vhost = "/", durable = true, auto_delete = false, arguments = {} }]
    exchanges   = []
    bindings    = []
  }
}

resource "random_password" "broker" {
  count   = local.supplied_password ? 0 : 1
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "credentials" {
  count = local.supplied_password ? 0 : 1
  metadata {
    name      = "${local.unique_name}-credentials"
    namespace = local.namespace
    labels    = local.labels
  }
  data = { password = random_password.broker[0].result }
}

resource "kubernetes_config_map_v1" "broker" {
  metadata {
    name      = "${local.unique_name}-config"
    namespace = local.namespace
    labels    = local.labels
  }
  data = {
    "20-definitions.conf" = "definitions.import_backend = local_filesystem\ndefinitions.local.path = /etc/rabbitmq/definitions/definitions.json"
    "definitions.json"    = jsonencode(local.definitions)
  }
}

resource "kubernetes_deployment_v1" "rabbitmq" {
  metadata {
    name      = local.unique_name
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { "radapp.io/resource" = local.resource_name }
    }
    template {
      metadata {
        labels = local.labels
        annotations = merge({
          "radapp.io/definitions-hash" = sha256(jsonencode(local.definitions))
          }, local.supplied_password ? {} : {
          "radapp.io/generated-password-hash" = sha256(random_password.broker[0].result)
        })
      }
      spec {
        init_container {
          name  = "generate-definitions"
          image = local.image
          # Kubelet must leave shell substitutions intact.
          command = ["sh", "-c", replace(<<-SCRIPT
            set -eu
            HASH=$(rabbitmqctl hash_password "$RABBITMQ_PASSWORD" | tail -n1 | tr -d '[:space:]')
            test -n "$HASH"
            sed "s|\"password_hash\":\"\"|\"password_hash\":\"$HASH\"|" /etc/rabbitmq/bootstrap/definitions.json > /etc/rabbitmq/definitions/definitions.json
          SCRIPT
          , "$", "$$")]
          env {
            name = "RABBITMQ_PASSWORD"
            value_from {
              secret_key_ref {
                name = local.credentials_name
                key  = "password"
              }
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/rabbitmq/bootstrap"
            read_only  = true
          }
          volume_mount {
            name       = "definitions"
            mount_path = "/etc/rabbitmq/definitions"
          }
        }
        container {
          name  = "rabbitmq"
          image = local.image
          port {
            container_port = local.port
          }
          readiness_probe {
            exec {
              command = ["rabbitmq-diagnostics", "-q", "check_running"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          volume_mount {
            name       = "definitions"
            mount_path = "/etc/rabbitmq/definitions"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/rabbitmq/conf.d/20-definitions.conf"
            sub_path   = "20-definitions.conf"
            read_only  = true
          }
          resources {
            requests = { memory = "256Mi" }
            limits   = { memory = "1Gi" }
          }
        }
        volume {
          name = "definitions"
          empty_dir {}
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.broker.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "rabbitmq" {
  metadata {
    name      = local.unique_name
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    type     = "ClusterIP"
    selector = { "radapp.io/resource" = local.resource_name }
    port {
      port = local.port
    }
  }
}

output "result" {
  value = {
    resources = concat(local.supplied_password ? [] : [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Secret/${kubernetes_secret_v1.credentials[0].metadata[0].name}"
      ], [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/ConfigMap/${kubernetes_config_map_v1.broker.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${kubernetes_service_v1.rabbitmq.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${kubernetes_deployment_v1.rabbitmq.metadata[0].name}"
    ])
    values = {
      host     = "${kubernetes_service_v1.rabbitmq.metadata[0].name}.${local.namespace}.svc.cluster.local"
      port     = local.port
      username = local.username
    }
    secrets = local.supplied_password ? {} : { password = random_password.broker[0].result }
  }
  sensitive = true
}
