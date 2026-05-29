terraform {
  required_version = ">= 1.5"
}

locals {
  properties         = var.context.resource.properties
  resource_name      = var.context.resource.name
  namespace          = var.context.runtime.kubernetes.namespace
  gateway_class_name = try(local.properties.gatewayClassName, "contour")
}

# Contour HTTPProxy does not have a separate Gateway resource. The matching
# Radius.Compute/routes recipe creates the HTTPProxy that represents ingress.
output "result" {
  description = "Resource IDs and values created by the Contour HTTPProxy gateway recipe."
  value = {
    resources = []
    values = {
      gatewayName      = local.resource_name
      gatewayNamespace = local.namespace
      gatewayClassName = local.gateway_class_name
    }
  }
}
