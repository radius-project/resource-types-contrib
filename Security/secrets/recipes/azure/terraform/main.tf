terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}

locals {
  secret_name = var.context.resource.name
  secret_data = try(var.context.resource.properties.data, null) != null ? var.context.resource.properties.data : {}
}

data "azurerm_resource_group" "rg" {
  name = var.context.azure.resourceGroup.name
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "vault" {
  name                       = "kv-${substr(md5("${local.secret_name}-${var.context.azure.resourceGroup.name}"), 0, 16)}"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = var.context.azure.resourceGroup.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = false
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    # Purge and Recover are required on destroy, because the azurerm provider
    # purges soft-deleted secrets by default.
    secret_permissions = [
      "Get",
      "List",
      "Set",
      "Delete",
      "Purge",
      "Recover",
    ]
  }

  lifecycle {
    # Resource preconditions apply to create/update plans, not destroy plans.
    precondition {
      condition = try(var.context.resource.properties.data, null) != null && alltrue([
        for secret in local.secret_data : try(secret.value, null) != null
      ])
      error_message = "Secret data and every secret value must be present and non-null on create or update."
    }
  }
}

resource "azurerm_key_vault_secret" "secrets" {
  for_each = local.secret_data
  name     = each.key
  # Radius does not send secret values when it deletes the resource. The
  # provider requires `value` to be set, so use an empty string when the value
  # is null. Terraform destroy does not write this value.
  value        = try(each.value.value, null) != null ? each.value.value : ""
  key_vault_id = azurerm_key_vault.vault.id
}

output "result" {
  value = {
    resources = [azurerm_key_vault.vault.id]
  }
}
