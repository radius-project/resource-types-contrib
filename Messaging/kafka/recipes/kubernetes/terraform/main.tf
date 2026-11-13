terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1, < 3.0"
    }
  }
}

locals {
  resource_name = var.context.resource.name
  namespace     = var.context.runtime.kubernetes.namespace
  host          = "${local.resource_name}.${local.namespace}.svc.cluster.local"
  topic         = try(var.context.resource.properties.topic, null) != null ? var.context.resource.properties.topic : "events"
  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = try(var.context.application.name, null) != null ? var.context.application.name : ""
    "radapp.io/environment"    = try(var.context.environment.name, null) != null ? var.context.environment.name : ""
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = split("/", var.context.resource.id)[5]
  }
  broker_environment = {
    CLUSTER_ID                                     = "MkU3OEVBNTcwNTJENDM2Qk"
    KAFKA_NODE_ID                                  = "1"
    KAFKA_PROCESS_ROLES                            = "broker,controller"
    KAFKA_LISTENERS                                = "PLAINTEXT://:9092,CONTROLLER://:9093"
    KAFKA_ADVERTISED_LISTENERS                     = "PLAINTEXT://${local.host}:9092"
    KAFKA_LISTENER_SECURITY_PROTOCOL_MAP           = "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT"
    KAFKA_CONTROLLER_LISTENER_NAMES                = "CONTROLLER"
    KAFKA_CONTROLLER_QUORUM_VOTERS                 = "1@localhost:9093"
    KAFKA_INTER_BROKER_LISTENER_NAME               = "PLAINTEXT"
    KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR         = "1"
    KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR = "1"
    KAFKA_TRANSACTION_STATE_LOG_MIN_ISR            = "1"
    KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS         = "0"
    KAFKA_AUTO_CREATE_TOPICS_ENABLE                = "false"
    KAFKA_LOG_DIRS                                 = "/var/lib/kafka/data/logs"
    KAFKA_HEAP_OPTS                                = "-Xms256m -Xmx512m"
    RADIUS_KAFKA_TOPIC                             = local.topic
  }
}

resource "kubernetes_persistent_volume_claim_v1" "data" {
  wait_until_bound = false
  metadata {
    name      = "${local.resource_name}-data"
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = { storage = "1Gi" }
    }
  }
}

resource "kubernetes_service_v1" "kafka" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    type                        = "ClusterIP"
    publish_not_ready_addresses = true
    selector                    = { "radapp.io/resource" = local.resource_name }
    port {
      name        = "kafka"
      port        = 9092
      target_port = "kafka"
    }
  }
}

resource "kubernetes_deployment_v1" "kafka" {
  metadata {
    name      = local.resource_name
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
      }
      spec {
        automount_service_account_token = false
        security_context {
          run_as_user     = 1000
          run_as_group    = 1000
          run_as_non_root = true
          fs_group        = 1000
        }
        container {
          name  = "kafka"
          image = "apache/kafka:3.9.1"
          dynamic "env" {
            for_each = local.broker_environment
            content {
              name  = env.key
              value = env.value
            }
          }
          port {
            container_port = 9092
            name           = "kafka"
          }
          lifecycle {
            post_start {
              exec {
                command = ["/bin/bash", "-ec", file("${path.module}/create-topic.sh")]
              }
            }
          }
          readiness_probe {
            exec {
              command = ["/bin/bash", "-ec", "/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic \"$RADIUS_KAFKA_TOPIC\""]
            }
            timeout_seconds = 15
            period_seconds  = 20
          }
          resources {
            requests = { cpu = "250m", memory = "1Gi" }
          }
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/kafka/data"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.data.metadata[0].name
          }
        }
      }
    }
  }
}

output "result" {
  value = {
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${kubernetes_deployment_v1.kafka.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${kubernetes_service_v1.kafka.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/PersistentVolumeClaim/${kubernetes_persistent_volume_claim_v1.data.metadata[0].name}"
    ]
    values  = { host = local.host }
    secrets = { connectionString = "${local.host}:9092" }
  }
}
