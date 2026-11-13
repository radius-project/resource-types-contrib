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
  resource_name  = "${var.context.resource.name}-blob"
  namespace      = var.context.runtime.kubernetes.namespace
  account_name   = "radiusstorage"
  container_name = try(var.context.resource.properties.containerName, null) == null ? "data" : var.context.resource.properties.containerName
  endpoint       = "http://${local.resource_name}.${local.namespace}.svc.cluster.local:10000/${local.account_name}"
  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = try(var.context.application.name, "")
    "radapp.io/environment"    = try(var.context.environment.name, "")
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = split("/", var.context.resource.id)[5]
  }
  # Keep the authenticated startup probe identical to the Bicep recipe.
  initialize_container = <<-JS
const http = require('http');
const crypto = require('crypto');
const [account, key] = process.env.AZURITE_ACCOUNTS.split(':');
const container = process.env.CONTAINER_NAME;
if (!/^[A-Za-z0-9+/]{86}==$/.test(key) || Buffer.from(key, 'base64').length !== 64 ||
    !/^(?!.*--)[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/.test(container)) {
  console.error('Invalid storage key or Blob container name');
  process.exit(1);
}
const date = new Date().toUTCString();
const headers = 'x-ms-date:' + date + '\nx-ms-version:2021-12-02\n';
const canonical = '/' + account + '/' + account + '/' + container + '\nrestype:container';
const message = ['PUT', '', '', '', '', '', '', '', '', '', '', ''].join('\n') + '\n' + headers + canonical;
const signature = crypto.createHmac('sha256', Buffer.from(key, 'base64')).update(message).digest('base64');
const request = http.request({
  host: '127.0.0.1', port: 10000, method: 'PUT',
  path: '/' + account + '/' + container + '?restype=container',
  headers: { 'x-ms-date': date, 'x-ms-version': '2021-12-02', 'Content-Length': 0,
    Authorization: 'SharedKey ' + account + ':' + signature }
}, response => {
  response.resume();
  if (response.statusCode !== 201 &&
      !(response.statusCode === 409 && response.headers['x-ms-error-code'] === 'ContainerAlreadyExists')) {
    console.error('Blob container initialization failed: HTTP ' + response.statusCode);
    process.exitCode = 1;
  }
});
request.setTimeout(3000, () => request.destroy(new Error('Blob initialization timeout')));
request.on('error', error => { console.error(error.message); process.exitCode = 1; });
request.end();
JS
}

resource "kubernetes_secret_v1" "credentials" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }
  data = {
    accounts = "${local.account_name}:${var.objectStorageAccountKey}"
  }
  type = "Opaque"
}

resource "kubernetes_persistent_volume_claim_v1" "storage" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.objectStorageStorageClassName == "" ? null : var.objectStorageStorageClassName
    resources {
      requests = {
        storage = var.objectStorageStorageSize
      }
    }
  }
  # Wait for the Pod to consume the claim when using WaitForFirstConsumer.
  wait_until_bound = false
}

resource "kubernetes_deployment_v1" "blob" {
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
        annotations = {
          "radapp.io/credential-hash" = sha256(var.objectStorageAccountKey)
        }
      }
      spec {
        automount_service_account_token = false
        container {
          name    = "azurite"
          image   = "mcr.microsoft.com/azure-storage/azurite:3.35.0"
          command = ["azurite-blob"]
          args    = ["--blobHost", "0.0.0.0", "--location", "/data", "--disableProductStyleUrl", "--disableTelemetry", "--silent"]
          env {
            name = "AZURITE_ACCOUNTS"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.credentials.metadata[0].name
                key  = "accounts"
              }
            }
          }
          env {
            name  = "CONTAINER_NAME"
            value = local.container_name
          }
          port {
            name           = "blob"
            container_port = 10000
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          startup_probe {
            exec {
              command = ["node", "-e", local.initialize_container]
            }
            period_seconds    = 5
            timeout_seconds   = 5
            failure_threshold = 60
          }
          readiness_probe {
            tcp_socket {
              port = "blob"
            }
            period_seconds = 5
          }
          liveness_probe {
            tcp_socket {
              port = "blob"
            }
            period_seconds = 10
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.storage.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "blob" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    type     = "ClusterIP"
    selector = { "radapp.io/resource" = local.resource_name }
    port {
      port        = 10000
      target_port = 10000
    }
  }
}

output "result" {
  value = {
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Secret/${kubernetes_secret_v1.credentials.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/PersistentVolumeClaim/${kubernetes_persistent_volume_claim_v1.storage.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${kubernetes_deployment_v1.blob.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${kubernetes_service_v1.blob.metadata[0].name}"
    ]
    values = {
      endpoint    = local.endpoint
      accountName = local.account_name
    }
    secrets = {
      accountKey       = var.objectStorageAccountKey
      connectionString = "DefaultEndpointsProtocol=http;AccountName=${local.account_name};AccountKey=${var.objectStorageAccountKey};BlobEndpoint=${local.endpoint};"
    }
  }
  sensitive = true
}
