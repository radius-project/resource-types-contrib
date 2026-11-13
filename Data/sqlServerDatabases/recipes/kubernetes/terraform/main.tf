terraform {
  required_version = ">= 1.7"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
  }
}

variable "context" {
  description = "Radius Recipe context."
  type        = any
}

variable "sqlServerAcceptEula" {
  description = "Set to Y only after the operator accepts the Microsoft SQL Server license terms. No default consent is supplied."
  type        = string
  validation {
    condition     = var.sqlServerAcceptEula == "Y"
    error_message = "The operator must explicitly accept the SQL Server license terms by setting sqlServerAcceptEula to Y."
  }
}

variable "sqlServerStorageSize" {
  description = "Persistent volume size. The namespace must have a default StorageClass."
  type        = string
  default     = "8Gi"
}

locals {
  resource_name = var.context.resource.name
  namespace     = var.context.runtime.kubernetes.namespace
  database      = var.context.resource.properties.database
  image         = "mcr.microsoft.com/mssql/server:2022-CU28-ubuntu-22.04"
  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = try(var.context.application.name, "")
    "radapp.io/environment"    = try(var.context.environment.name, "")
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = split("/", var.context.resource.id)[5]
  }
}

resource "kubernetes_secret_v1" "credentials" {
  metadata {
    name      = "${local.resource_name}-credentials"
    namespace = local.namespace
    labels    = local.labels
  }
  data = {
    USERNAME = var.context.resource.properties.username
    PASSWORD = sensitive(var.context.resource.properties.password)
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
      requests = { storage = var.sqlServerStorageSize }
    }
  }
}

resource "kubernetes_deployment_v1" "server" {
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
        node_selector = {
          "kubernetes.io/os"   = "linux"
          "kubernetes.io/arch" = "amd64"
        }
        security_context {
          fs_group        = 10001
          run_as_user     = 10001
          run_as_group    = 10001
          run_as_non_root = true
        }
        termination_grace_period_seconds = 60
        container {
          name    = "sqlserver"
          image   = local.image
          command = ["/bin/bash", "-ec", replace(file("${path.module}/bootstrap.sh"), "$", "$$")]
          env {
            name  = "ACCEPT_EULA"
            value = var.sqlServerAcceptEula
          }
          env {
            name  = "MSSQL_PID"
            value = "Developer"
          }
          env {
            name  = "MSSQL_TCP_PORT"
            value = "1433"
          }
          env {
            name  = "MSSQL_MEMORY_LIMIT_MB"
            value = "2048"
          }
          env {
            name  = "RADIUS_DATABASE"
            value = local.database
          }
          env {
            name = "RADIUS_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.credentials.metadata[0].name
                key  = "USERNAME"
              }
            }
          }
          env {
            name = "MSSQL_SA_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.credentials.metadata[0].name
                key  = "PASSWORD"
              }
            }
          }
          port {
            name           = "sqlserver"
            container_port = 1433
          }
          resources {
            requests = { cpu = "2", memory = "2Gi" }
            limits   = { memory = "3Gi" }
          }
          readiness_probe {
            exec {
              command = ["/bin/bash", "-ec", "SQLCMDPASSWORD=\"$MSSQL_SA_PASSWORD\" /opt/mssql-tools18/bin/sqlcmd -S tcp:127.0.0.1,1433 -U \"$RADIUS_USERNAME\" -d \"$RADIUS_DATABASE\" -C -x -b -l 3 -t 3 -Q \"SELECT 1\" >/dev/null 2>&1"]
            }
            timeout_seconds = 10
            period_seconds  = 10
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/opt/mssql"
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

resource "kubernetes_service_v1" "server" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    type     = "ClusterIP"
    selector = { "radapp.io/resource" = local.resource_name }
    port {
      port        = 1433
      target_port = "sqlserver"
    }
  }
}

output "result" {
  value = {
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Secret/${kubernetes_secret_v1.credentials.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/PersistentVolumeClaim/${kubernetes_persistent_volume_claim_v1.data.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${kubernetes_deployment_v1.server.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${kubernetes_service_v1.server.metadata[0].name}"
    ]
    values = {
      host     = "${kubernetes_service_v1.server.metadata[0].name}.${local.namespace}.svc.cluster.local"
      port     = 1433
      database = local.database
    }
  }
}
