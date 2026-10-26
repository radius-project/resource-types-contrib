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

  # Dapr loads the component only into the listed app IDs. Without `scopes`,
  # every Dapr app in the namespace can load the component, so omit the field
  # when the list is empty.
  scope_list = try(local.properties.scopes, null) != null ? tolist(local.properties.scopes) : []
  component_scopes = {
    for key, value in { scopes = local.scope_list } : key => value
    if length(local.scope_list) > 0
  }

  # The Dapr sidecar reads Kubernetes secrets with the ServiceAccount of its
  # Pod. The Recipe gives that ServiceAccount `get` access to the named secrets
  # only. Without allowedSecrets, the Recipe gives no access, and Kubernetes
  # denies all secret reads unless the platform engineer grants access.
  allowed_secrets    = try(local.properties.allowedSecrets, null) != null ? tolist(local.properties.allowedSecrets) : []
  grant_secret_reads = length(local.allowed_secrets) > 0
  secret_reader_name = "daprsecrets-${substr(sha1(var.context.resource.id), 0, 13)}"
}

resource "kubernetes_manifest" "dapr_component" {
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

  lifecycle {
    # Kubernetes RBAC applies only to the Kubernetes secret store. Reject
    # allowedSecrets for other component types instead of ignoring it.
    precondition {
      condition     = !local.grant_secret_reads || local.dapr_type == "secretstores.kubernetes"
      error_message = "allowedSecrets applies only to the secretstores.kubernetes component type. Remove allowedSecrets, or control access in the secret store that componentType selects."
    }
  }
}

resource "kubernetes_role_v1" "secret_reader" {
  count = local.grant_secret_reads ? 1 : 0

  metadata {
    name      = local.secret_reader_name
    namespace = local.namespace
    labels    = local.labels
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = local.allowed_secrets
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "secret_reader" {
  count = local.grant_secret_reads ? 1 : 0

  metadata {
    name      = local.secret_reader_name
    namespace = local.namespace
    labels    = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.secret_reader[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.daprServiceAccountName
    namespace = local.namespace
  }
}

output "result" {
  value = {
    resources = concat(
      ["/planes/kubernetes/local/namespaces/${local.namespace}/providers/dapr.io/Component/${local.resource_name}"],
      local.grant_secret_reads ? [
        "/planes/kubernetes/local/namespaces/${local.namespace}/providers/rbac.authorization.k8s.io/Role/${local.secret_reader_name}",
        "/planes/kubernetes/local/namespaces/${local.namespace}/providers/rbac.authorization.k8s.io/RoleBinding/${local.secret_reader_name}"
      ] : []
    )
    values = {
      componentName = kubernetes_manifest.dapr_component.manifest.metadata.name
      version       = local.dapr_version
    }
  }
}
