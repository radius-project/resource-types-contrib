mock_provider "kubernetes" {}

variables {
  context = {
    application = null
    environment = null
    runtime     = { kubernetes = { namespace = "storage-test" } }
    resource = {
      id         = "/planes/radius/local/resourceGroups/test/providers/Radius.Storage/objectStorage/store"
      name       = "store"
      type       = "Radius.Storage/objectStorage"
      properties = {}
    }
  }
}

run "defaults" {
  command = apply
  assert {
    condition     = output.result.values.endpoint == "http://store-blob.storage-test.svc.cluster.local:10000/radiusstorage" && output.result.values.accountName == "radiusstorage"
    error_message = "Use an in-namespace path-style Blob endpoint and the configured account."
  }
  assert {
    condition     = output.result.secrets.connectionString == "DefaultEndpointsProtocol=http;AccountName=radiusstorage;AccountKey=${random_bytes.account_key.base64};BlobEndpoint=${output.result.values.endpoint};" && output.result.secrets.accountKey == random_bytes.account_key.base64 && can(regex("^[A-Za-z0-9+/]{86}==$", output.result.secrets.accountKey))
    error_message = "Return consistent credentials in the Radius secrets contract."
  }
  assert {
    condition     = kubernetes_secret_v1.credentials.data.accounts == "radiusstorage:${random_bytes.account_key.base64}" && kubernetes_deployment_v1.blob.spec[0].template[0].spec[0].container[0].env[0].value_from[0].secret_key_ref[0].key == "accounts"
    error_message = "Azurite must load its custom account from a Secret, not use the public emulator key."
  }
  assert {
    condition     = kubernetes_deployment_v1.blob.spec[0].template[0].spec[0].container[0].env[1].value == "data" && kubernetes_deployment_v1.blob.spec[0].template[0].spec[0].container[0].startup_probe[0].exec[0].command[2] == local.initialize_container
    error_message = "Create the default named container before readiness."
  }
  assert {
    condition     = kubernetes_deployment_v1.blob.spec[0].strategy[0].type == "Recreate" && tonumber(kubernetes_deployment_v1.blob.spec[0].replicas) == 1 && kubernetes_persistent_volume_claim_v1.storage.spec[0].resources[0].requests.storage == "1Gi" && !kubernetes_persistent_volume_claim_v1.storage.wait_until_bound
    error_message = "Use one persistent writer without a WaitForFirstConsumer dependency deadlock."
  }
  assert {
    condition     = toset(output.result.resources) == toset(["/planes/kubernetes/local/namespaces/storage-test/providers/core/Secret/store-blob", "/planes/kubernetes/local/namespaces/storage-test/providers/core/PersistentVolumeClaim/store-blob", "/planes/kubernetes/local/namespaces/storage-test/providers/apps/Deployment/store-blob", "/planes/kubernetes/local/namespaces/storage-test/providers/core/Service/store-blob"])
    error_message = "Track all four Kubernetes objects for Radius cleanup."
  }
}

run "custom_container_and_storage" {
  command = plan
  variables {
    objectStorageStorageSize      = "4Gi"
    objectStorageStorageClassName = "fixture-class"
    context = {
      runtime = { kubernetes = { namespace = "custom" } }
      resource = {
        id         = "/planes/radius/local/resourceGroups/test/providers/Radius.Storage/objectStorage/store"
        name       = "store"
        type       = "Radius.Storage/objectStorage"
        properties = { containerName = "app-files" }
      }
    }
  }
  assert {
    condition     = kubernetes_deployment_v1.blob.spec[0].template[0].spec[0].container[0].env[1].value == "app-files" && kubernetes_persistent_volume_claim_v1.storage.spec[0].resources[0].requests.storage == "4Gi" && kubernetes_persistent_volume_claim_v1.storage.spec[0].storage_class_name == "fixture-class"
    error_message = "Honor developer containerName and operator storage settings."
  }
}

run "reapply_keeps_key" {
  command = apply
  assert {
    condition     = output.result.secrets.accountKey == run.defaults.result.secrets.accountKey && kubernetes_secret_v1.credentials.data.accounts == "radiusstorage:${run.defaults.result.secrets.accountKey}"
    error_message = "Repeated applies must preserve the state-backed random key and server credentials."
  }
}
