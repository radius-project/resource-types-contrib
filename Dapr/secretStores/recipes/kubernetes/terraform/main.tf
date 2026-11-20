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
  properties       = var.context.resource.properties

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }

  # When the resource does not set a component type, deploy a
  # secretstores.kubernetes component. It reads Kubernetes secrets in the
  # namespace of the component and needs no backing infrastructure.
  requested_type = try(local.properties.componentType, null)
  dapr_type      = local.requested_type == null || local.requested_type == "" ? "secretstores.kubernetes" : local.requested_type
  dapr_version   = try(local.properties.version, null) != null ? local.properties.version : "v1"

  component_metadata = [
    for name, entry in try(merge(local.properties.metadata), {}) : merge({ name = name }, entry)
  ]

  # Never emit an empty list: Dapr treats it as namespace-wide access.
  scope_list        = try(local.properties.scopes, null) != null ? tolist(local.properties.scopes) : var.daprAllowedAppIds
  component_scopes  = { scopes = local.scope_list }
  resource_metadata = try(merge(local.properties.metadata), {})
  invalid_metadata = [
    for name, entry in local.resource_metadata : name if !try(
      trimspace(name) != "" && length(keys(entry)) == 1 &&
      (contains(keys(entry), "value") != contains(keys(entry), "secretKeyRef")) &&
      (contains(keys(entry), "secretKeyRef") ? (
        length(keys(entry.secretKeyRef)) == 2 &&
        trimspace(entry.secretKeyRef.name) != "" && trimspace(entry.secretKeyRef.key) != ""
      ) : entry.value != null), false
    )
  ]
  supported_properties = ["environment", "application", "connections", "codeReference", "recipe", "status", "componentType", "version", "metadata", "scopes", "componentName"]
  input_errors = compact([
    length(local.scope_list) == 0 ? "Set nonempty scopes or platform daprAllowedAppIds." : "",
    alltrue([for id in local.scope_list : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", id)) && length(id) <= 63]) ? "" : "scopes must contain valid Dapr app IDs of 1 to 63 lowercase letters, digits, or hyphens, with a letter or digit at each end.",
    length(distinct(local.scope_list)) == length(local.scope_list) ? "" : "scopes must not contain duplicate IDs.",
    length(var.daprAllowedAppIds) == 0 || length(setsubtract(local.scope_list, var.daprAllowedAppIds)) == 0 ? "" : "scopes must be a subset of platform daprAllowedAppIds.",
    length(local.invalid_metadata) == 0 ? "" : "Each metadata entry must set exactly one of value or secretKeyRef; secretKeyRef must contain nonempty name and key only.",
    length(setsubtract(keys(local.properties), local.supported_properties)) == 0 ? "" : "Unsupported resource property. Use the Radius.Dapr/secretStores schema.",
    !contains(keys(local.properties), "componentType") || can(regex("^secretstores\\.[^\\s]+$", local.requested_type)) ? "" : "componentType must name a secretstores component, or be omitted for the default.",
    can(regex("^[^\\s]+$", local.dapr_version)) ? "" : "version must be nonempty, or omitted for v1."
  ])
}

resource "terraform_data" "validate_inputs" {
  lifecycle {
    precondition {
      condition     = length(local.input_errors) == 0
      error_message = "Invalid Radius.Dapr/secretStores inputs. ${join(" ", local.input_errors)} Fix the inputs and deploy again."
    }
  }
}

resource "kubernetes_manifest" "dapr_component" {
  depends_on = [terraform_data.validate_inputs]
  manifest = merge({
    apiVersion = "dapr.io/v1alpha1"
    kind       = "Component"
    metadata = {
      name      = local.resource_name
      namespace = local.namespace
      labels    = local.labels
    }
    spec = {
      type     = local.dapr_type
      version  = local.dapr_version
      metadata = local.component_metadata
    }
  }, local.component_scopes)
}

output "result" {
  value = {
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/dapr.io/Component/${local.resource_name}"
    ]
    values = {
      componentName = kubernetes_manifest.dapr_component.manifest.metadata.name
      version       = local.dapr_version
    }
  }
}
