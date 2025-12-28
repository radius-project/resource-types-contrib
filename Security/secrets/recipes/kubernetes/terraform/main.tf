terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
  }
}

# ========================================
# Common Radius variables
# ========================================

variable "context" {
  description = "The Radius Recipe context variable. See https://docs.radapp.io/reference/context-schema/."
  type = any
}

locals {
  resource_name = var.context.resource.name
  namespace     = var.context.runtime.kubernetes.namespace
  resource_properties = try(var.context.resource.properties, {})

  # Extract last segment from environment path for labels
  environment_id    = try(local.resource_properties.environment, "")
  environment_parts = local.environment_id != "" ? split("/", local.environment_id) : []
  environment_label = length(local.environment_parts) > 0 ? local.environment_parts[length(local.environment_parts) - 1] : ""

  # Extract resource group name
  # Index 4 is the resource group name
  resource_group_name = split("/", var.context.resource.id)[4]

  # Application name
  application_name = var.context.application != null ? var.context.application.name : ""

  # Common labels
  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_label
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group_name
  }
}

# ========================================
# Kubernetes Secret variables
# ========================================

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
    for k, v in local.secret_data : k => v.value
    if try(v.encoding, "") != "base64"
  }
  
  # Determine Kubernetes secret type
  secret_type = (
    local.secret_kind == "certificate-pem" ? "kubernetes.io/tls" :
    local.secret_kind == "basicAuthentication" ? "kubernetes.io/basic-auth" :
    "Opaque"
  )
}

# ========================================
# Kubernetes Secret resource
# ========================================

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
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }
  
  type = local.secret_type
  data = length(local.string_data) > 0 ? local.string_data : {}
  binary_data = length(local.base64_data) > 0 ? local.base64_data : {}
}

# ========================================
# Output Radius result 
# ========================================

output "result" {
  value = {
    resources = [
        "/planes/kubernetes/local/namespaces/${kubernetes_secret.secret.metadata[0].namespace}/providers/core/Secret/${kubernetes_secret.secret.metadata[0].name}"
    ]
  }
}
