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
  application_name = var.context.application != null ? var.context.application.name : ""
  environment_name = var.context.environment != null ? var.context.environment.name : ""
  resource_group   = element(split("/", var.context.resource.id), 5)
  namespace        = var.context.runtime.kubernetes.namespace
  port             = 9092
  tag              = "4.3.1"
  topic_input      = try(var.context.resource.properties.topic, null)
  topic            = local.topic_input != null ? local.topic_input : "events"

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }

  host = "${local.resource_name}.${local.namespace}.svc.cluster.local"

  # Starts the broker, then creates the topic through the in-Pod LOCAL listener
  # (127.0.0.1:9094). The PLAINTEXT listener advertises the Service DNS name,
  # which has no endpoints until the Pod is ready, so the topic cannot be
  # created through it. The readiness probe passes only after the topic exists.
  # SIGTERM is forwarded to the broker so it shuts down cleanly.
  start_script = <<-EOT
    set -u
    if ! [[ "$TOPIC_NAME" =~ ^[A-Za-z0-9._-]{1,249}$ ]] || [[ "$TOPIC_NAME" == "." || "$TOPIC_NAME" == ".." ]]; then
      echo "Invalid Kafka topic name: $TOPIC_NAME" >&2
      exit 1
    fi
    /etc/kafka/docker/run &
    broker=$!
    trap 'kill -TERM "$broker" 2>/dev/null' TERM INT
    until (exec 3<>/dev/tcp/127.0.0.1/9094) 2>/dev/null; do
      kill -0 "$broker" 2>/dev/null || break
      sleep 1
    done
    until KAFKA_HEAP_OPTS=-Xmx256m /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:9094 --create --if-not-exists --topic "$TOPIC_NAME" --partitions 1 --replication-factor 1; do
      kill -0 "$broker" 2>/dev/null || break
      sleep 2
    done
    if kill -0 "$broker" 2>/dev/null; then
      touch /tmp/topic-ready
    fi
    wait "$broker"
    status=$?
    while kill -0 "$broker" 2>/dev/null; do
      wait "$broker"
      status=$?
    done
    exit "$status"
  EOT
}

# In-cluster Kafka Deployment. A single Apache Kafka node in KRaft mode, acting
# as both broker and controller. Clients connect over plaintext on port 9092
# with no TLS and no authentication.
resource "kubernetes_deployment" "kafka" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    # Single-replica, non-persistent broker: Recreate tears down the old Pod
    # before starting the new one on update, so two divergent brokers never
    # back the same Service at once (default RollingUpdate would run both).
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
      }

      spec {
        # The image turns every KAFKA_* variable into a broker setting. Service
        # links would inject KAFKA_SERVICE_HOST, KAFKA_PORT and similar
        # variables whenever a Service named `kafka` exists in the namespace.
        enable_service_links = false

        container {
          name    = "kafka"
          image   = "apache/kafka:${local.tag}"
          command = ["bash", "-c", local.start_script]

          port {
            container_port = local.port
          }

          env {
            name  = "KAFKA_NODE_ID"
            value = "1"
          }

          env {
            name  = "KAFKA_PROCESS_ROLES"
            value = "broker,controller"
          }

          env {
            name  = "KAFKA_LISTENERS"
            value = "PLAINTEXT://:${local.port},CONTROLLER://localhost:9093,LOCAL://127.0.0.1:9094"
          }

          env {
            name  = "KAFKA_ADVERTISED_LISTENERS"
            value = "PLAINTEXT://${local.host}:${local.port},LOCAL://127.0.0.1:9094"
          }

          env {
            name  = "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP"
            value = "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,LOCAL:PLAINTEXT"
          }

          env {
            name  = "KAFKA_CONTROLLER_LISTENER_NAMES"
            value = "CONTROLLER"
          }

          # The single node only ever talks to itself, so keep broker traffic
          # on the in-Pod listener rather than the Service.
          env {
            name  = "KAFKA_INTER_BROKER_LISTENER_NAME"
            value = "LOCAL"
          }

          env {
            name  = "KAFKA_CONTROLLER_QUORUM_VOTERS"
            value = "1@localhost:9093"
          }

          env {
            name  = "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR"
            value = "1"
          }

          env {
            name  = "KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR"
            value = "1"
          }

          env {
            name  = "KAFKA_TRANSACTION_STATE_LOG_MIN_ISR"
            value = "1"
          }

          env {
            name  = "KAFKA_SHARE_COORDINATOR_STATE_TOPIC_REPLICATION_FACTOR"
            value = "1"
          }

          env {
            name  = "KAFKA_SHARE_COORDINATOR_STATE_TOPIC_MIN_ISR"
            value = "1"
          }

          env {
            name  = "KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS"
            value = "0"
          }

          env {
            name  = "KAFKA_LOG_DIRS"
            value = "/var/lib/kafka/data"
          }

          env {
            name  = "KAFKA_HEAP_OPTS"
            value = "-Xms512m -Xmx512m"
          }

          env {
            name  = "TOPIC_NAME"
            value = local.topic
          }

          readiness_probe {
            exec {
              command = ["bash", "-c", "test -f /tmp/topic-ready"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          resources {
            requests = {
              memory = "1Gi"
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/kafka/data"
          }
        }

        volume {
          name = "data"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "kafka" {
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

output "result" {
  value = {
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${kubernetes_service.kafka.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${kubernetes_deployment.kafka.metadata[0].name}"
    ]
    values = {
      host = local.host
    }
    secrets = {
      # The in-cluster broker runs without TLS or authentication, so the
      # connection string is the plain bootstrap server host:9092. Radius still
      # materializes it into the managed Radius.Security/secrets resource; it is
      # never written onto the resource.
      connectionString = "${local.host}:${local.port}"
    }
  }
  sensitive = true
}
