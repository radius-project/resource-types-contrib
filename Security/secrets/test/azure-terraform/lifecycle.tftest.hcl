mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      location = "westus"
    }
  }
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000002"
      object_id = "00000000-0000-0000-0000-000000000003"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/fixture-group/providers/Microsoft.KeyVault/vaults/fixture-vault"
    }
  }
}

variables {
  context = {
    resource = {
      name = "fixture-secret"
      properties = {
        data = {
          username = { value = "fixture-user" }
          password = { value = "fixture-value-not-a-real-secret" }
        }
      }
    }
    azure = {
      resourceGroup = { name = "fixture-group" }
    }
  }
}

run "legacy_deploy" {
  command = apply

  assert {
    condition     = toset(keys(azurerm_key_vault_secret.secrets)) == toset(["username", "password"])
    error_message = "An absent operation must preserve both secret instances."
  }
  assert {
    condition     = azurerm_key_vault_secret.secrets["password"].value == var.context.resource.properties.data.password.value
    error_message = "Deploy must forward the original secret value."
  }
  assert {
    condition     = contains(one(azurerm_key_vault.vault.access_policy).secret_permissions, "Purge")
    error_message = "The recipe identity needs Purge on its own vault for AzureRM's default secret destruction."
  }
}

run "explicit_deploy" {
  command = apply
  variables {
    context = merge(var.context, { operation = "deploy" })
  }
  assert {
    condition     = length(azurerm_key_vault_secret.secrets) == 2
    error_message = "Explicit deploy must preserve both secret instances."
  }
}

run "redacted_delete" {
  command = apply
  variables {
    context = merge(var.context, {
      operation = "delete"
      resource = merge(var.context.resource, {
        properties = {
          data = {
            username = { value = null }
            password = { value = null }
          }
        }
      })
    })
  }
  assert {
    condition     = length(azurerm_key_vault_secret.secrets) == 0
    error_message = "Explicit delete must remove existing secret instances without their original values."
  }
}

run "repeat_delete" {
  command = apply
  variables {
    context = merge(var.context, {
      operation = "delete"
      resource = merge(var.context.resource, {
        properties = { data = { username = { value = null }, password = { value = null } } }
      })
    })
  }
  assert {
    condition     = length(azurerm_key_vault_secret.secrets) == 0
    error_message = "Repeated delete must remain empty."
  }
}

run "partial_inventory_deploy" {
  command = apply
  variables {
    context = merge(var.context, {
      operation = "deploy"
      resource = merge(var.context.resource, {
        properties = { data = { username = { value = "fixture-user" } } }
      })
    })
  }
  assert {
    condition     = toset(keys(azurerm_key_vault_secret.secrets)) == toset(["username"])
    error_message = "The partial-state fixture must contain only username."
  }
}

run "partial_inventory_delete" {
  command = apply
  variables {
    context = merge(var.context, {
      operation = "delete"
      resource = merge(var.context.resource, {
        properties = { data = { username = { value = null }, password = { value = null } } }
      })
    })
  }
  assert {
    condition     = length(azurerm_key_vault_secret.secrets) == 0
    error_message = "Delete must handle input keys whose instances are absent from state."
  }
}
