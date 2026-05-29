terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
  }
}

# Local values for processing secret data
locals {
  secret_data = var.context.resource.properties.data
  secret_kind = try(var.context.resource.properties.kind, "generic")
  secret_name = var.context.resource.name
  
  # Separate data based on encoding
  base64_data = {
    for k, v in local.secret_data : k => v.value
    if try(v.encoding, "") == "base64"
  }
  
  string_data = {
    for k, v in local.secret_data : k => base64encode(v.value)
    if try(v.encoding, "") != "base64"
  }
  
  # Determine Kubernetes secret type
  secret_type = (
    local.secret_kind == "certificate-pem" ? "kubernetes.io/tls" :
    local.secret_kind == "basicAuthentication" ? "kubernetes.io/basic-auth" :
    "Opaque"
  )
  
}

resource "kubernetes_secret" "secret" {
  # Validation preconditions - these will stop deployment if they fail
  lifecycle {
    precondition {
      condition = (
        local.secret_kind != "certificate-pem" || 
        (contains(keys(local.secret_data), "tls.crt") && 
         contains(keys(local.secret_data), "tls.key"))
      )
      error_message = "certificate-pem secrets must contain keys tls.crt and tls.key"
    }
    
    precondition {
      condition = (
        local.secret_kind != "basicAuthentication" ||
        (contains(keys(local.secret_data), "username") && 
         contains(keys(local.secret_data), "password"))
      )
      error_message = "basicAuthentication secrets must contain keys username and password"
    }
    
    precondition {
      condition = (
        local.secret_kind != "azureWorkloadIdentity" ||
        (contains(keys(local.secret_data), "clientId") && 
         contains(keys(local.secret_data), "tenantId"))
      )
      error_message = "azureWorkloadIdentity secrets must contain keys clientId and tenantId"
    }
    
    precondition {
      condition = (
        local.secret_kind != "awsIRSA" ||
        contains(keys(local.secret_data), "roleARN")
      )
      error_message = "awsIRSA secrets must contain key roleARN"
    }
  }
  
  metadata {
    name      = local.secret_name
    namespace = var.context.runtime.kubernetes.namespace
    
    labels = {
      resource = var.context.resource.name
      app      = var.context.application != null ? var.context.application.name : ""
    }
  }
  
  type = local.secret_type
  data = length(local.string_data) > 0 ? local.string_data : {}
  binary_data = length(local.base64_data) > 0 ? local.base64_data : {}
}
