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
  resource_name = var.context.resource.name
  # A unique per-resource name so two rabbitMQ resources that share a display
  # name (or the same name across recreates) never collide on their Kubernetes
  # objects.
  unique_name      = "${local.resource_name}-${substr(sha256(var.context.resource.id), 0, 13)}"
  application_name = var.context.application != null ? var.context.application.name : ""
  environment_name = var.context.environment != null ? var.context.environment.name : ""
  resource_group   = element(split("/", var.context.resource.id), 5)
  namespace        = var.context.runtime.kubernetes.namespace
  port             = 5672
  tag              = "4-alpine"

  # The default `guest` account is restricted to loopback connections, so a
  # client running in another Pod cannot authenticate as `guest`. A non-`guest`
  # user is not loopback-restricted, so the broker accepts AMQP connections from
  # workload Pods. The username is not sensitive and comes from the resource
  # properties (default `radius`). When supplied, `password` references a
  # Radius.Security/secrets resource. Otherwise, the Recipe generates a random
  # password and returns it through Radius managed secrets. Both paths mount the
  # password through secret_key_ref.
  username_input = try(var.context.resource.properties.username, null)
  username       = local.username_input != null ? local.username_input : "radius"

  password_input                   = try(var.context.resource.properties.password, null)
  password_secret_id               = local.password_input != null ? local.password_input : ""
  uses_supplied_password           = local.password_secret_id != ""
  fallback_credentials_secret_name = "${local.unique_name}-credentials"
  credentials_secret_name          = local.uses_supplied_password ? element(split("/", local.password_secret_id), length(split("/", local.password_secret_id)) - 1) : local.fallback_credentials_secret_name

  # The queue is pre-provisioned on the broker (see the definitions ConfigMap and
  # the init container below) so the named queue exists as soon as the broker
  # is ready, rather than relying on a client to declare it first.
  queue_input = try(var.context.resource.properties.queue, null)
  queue       = local.queue_input != null ? local.queue_input : "jobs"

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }

  # Writes the broker definitions file (vhost, user, permissions, and the
  # pre-provisioned queue). rabbitmqctl hash_password computes the password hash
  # offline, so the plaintext password is only read at runtime from the
  # Kubernetes Secret.
  generate_definitions_script = chomp(<<-EOT
    set -eu
    HASH=$(rabbitmqctl hash_password "$RABBITMQ_PASSWORD" | tail -n1 | tr -d '[:space:]')
    printf '{"users":[{"name":"%s","password_hash":"%s","hashing_algorithm":"rabbit_password_hashing_sha256","tags":["administrator"]}],"vhosts":[{"name":"/"}],"permissions":[{"user":"%s","vhost":"/","configure":".*","write":".*","read":".*"}],"queues":[{"name":"%s","vhost":"/","durable":true,"auto_delete":false,"arguments":{}}],"exchanges":[],"bindings":[]}\n' "$RABBITMQ_USER" "$HASH" "$RABBITMQ_USER" "$RABBITMQ_QUEUE" > /etc/rabbitmq/definitions/definitions.json
  EOT
  )

  host = "${kubernetes_service.rabbitmq.metadata[0].name}.${kubernetes_service.rabbitmq.metadata[0].namespace}.svc.cluster.local"
}

# Random fallback password used when the resource does not reference a password
# secret. It is kept in the Terraform state, so it stays the same across
# later deployments of the same resource.
resource "random_password" "generated" {
  count   = local.uses_supplied_password ? 0 : 1
  length  = 32
  special = false
}

resource "kubernetes_secret" "fallback_credentials" {
  count = local.uses_supplied_password ? 0 : 1

  metadata {
    name      = local.fallback_credentials_secret_name
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    password = random_password.generated[0].result
  }
}

# Points the broker at a definitions file (written by the init container below)
# so it imports the vhost, user, permissions, and the pre-provisioned queue on
# boot. The file lives in a shared emptyDir; this ConfigMap only carries the
# small conf.d snippet that enables the import.
resource "kubernetes_config_map" "broker_config" {
  metadata {
    name      = "${local.unique_name}-config"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    "20-definitions.conf" = join("\n", [
      "definitions.import_backend = local_filesystem",
      "definitions.local.path = /etc/rabbitmq/definitions/definitions.json",
    ])
  }
}

resource "kubernetes_deployment" "rabbitmq" {
  metadata {
    name      = local.unique_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    # A single-replica, non-persistent broker. Recreate tears down the old Pod
    # before starting the new one on update, so two divergent brokers never back
    # the same Service at once (default RollingUpdate would run both).
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "radapp.io/resource" = local.resource_name
      }
    }

    template {
      metadata {
        labels = local.labels
        # A new generated password changes the Pod template so the broker
        # restarts and reads the updated Secret during deployment.
        annotations = local.uses_supplied_password ? tomap({}) : tomap({
          "radapp.io/generated-password-hash" = substr(sha256(random_password.generated[0].result), 0, 13)
        })
      }

      spec {
        # Generates the broker definitions file into a shared volume before the
        # broker starts. The plaintext password is injected only at runtime from
        # a Kubernetes Secret via secret_key_ref; it is never baked into the pod
        # spec, definitions, or image.
        init_container {
          name    = "generate-definitions"
          image   = "rabbitmq:${local.tag}"
          command = ["sh", "-c", local.generate_definitions_script]

          env {
            name  = "RABBITMQ_USER"
            value = local.username
          }

          env {
            # Sourced from either the supplied or Recipe-created Kubernetes
            # Secret, never a literal value in the pod spec.
            name = "RABBITMQ_PASSWORD"
            value_from {
              secret_key_ref {
                name = local.credentials_secret_name
                key  = "password"
              }
            }
          }

          env {
            name  = "RABBITMQ_QUEUE"
            value = local.queue
          }

          volume_mount {
            name       = "definitions"
            mount_path = "/etc/rabbitmq/definitions"
          }
        }

        # The running RabbitMQ broker. On boot it imports the definitions file,
        # which creates the non-loopback user and the pre-provisioned queue, then
        # accepts AMQP 0-9-1 connections from workload Pods on port 5672.
        container {
          name  = "rabbitmq"
          image = "rabbitmq:${local.tag}"

          port {
            container_port = local.port
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
            requests = {
              memory = "256Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "definitions"
          empty_dir {}
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.broker_config.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubernetes_secret.fallback_credentials]
}

resource "kubernetes_service" "rabbitmq" {
  metadata {
    name      = local.unique_name
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

output "result" {
  value = {
    resources = concat(local.uses_supplied_password ? [] : [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Secret/${local.fallback_credentials_secret_name}"
      ], [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/ConfigMap/${kubernetes_config_map.broker_config.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${kubernetes_service.rabbitmq.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${kubernetes_deployment.rabbitmq.metadata[0].name}"
    ])
    values = {
      # Non-secret connection values. Clients combine these with either their
      # supplied password secret or the Recipe-generated managed secret.
      host     = local.host
      port     = local.port
      username = local.username
    }
    secrets = local.uses_supplied_password ? tomap({}) : tomap({
      password = random_password.generated[0].result
    })
  }
  sensitive = true
}
