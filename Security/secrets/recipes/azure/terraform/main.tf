terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
  }
}

locals {
  secret_name = var.context.resource.name
  secret_data = var.context.resource.properties.data
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
  enable_rbac_authorization  = false
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = [
      "Get",
      "List",
      "Set",
      "Delete",
    ]
  }
}

resource "azurerm_key_vault_secret" "secrets" {
  for_each     = local.secret_data
  name         = each.key
  value        = each.value.value
  key_vault_id = azurerm_key_vault.vault.id
}

output "result" {
  value = {
    resources = [azurerm_key_vault.vault.id]
  }
}
