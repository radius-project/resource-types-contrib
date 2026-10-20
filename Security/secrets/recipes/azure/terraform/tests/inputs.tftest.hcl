mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      location = "westus3"
    }
  }
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000001"
      object_id = "00000000-0000-0000-0000-000000000002"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/recipe-test/providers/Microsoft.KeyVault/vaults/recipe-test"
    }
  }
}

variables {
  context = {
    azure = { resourceGroup = { name = "recipe-test" } }
    resource = {
      name = "test-secrets"
      properties = {
        data = {
          password = { value = "original-test-value" }
        }
      }
    }
  }
}

run "reject_null_value_on_create" {
  command = plan
  variables {
    context = {
      azure = { resourceGroup = { name = "recipe-test" } }
      resource = {
        name       = "test-secrets"
        properties = { data = { password = { value = null } } }
      }
    }
  }
  expect_failures = [azurerm_key_vault.vault]
}

run "reject_missing_value_on_create" {
  command = plan
  variables {
    context = {
      azure = { resourceGroup = { name = "recipe-test" } }
      resource = {
        name       = "test-secrets"
        properties = { data = { password = {} } }
      }
    }
  }
  expect_failures = [azurerm_key_vault.vault]
}

run "reject_null_data_on_create" {
  command = plan
  variables {
    context = {
      azure = { resourceGroup = { name = "recipe-test" } }
      resource = {
        name       = "test-secrets"
        properties = { data = null }
      }
    }
  }
  expect_failures = [azurerm_key_vault.vault]
}

run "reject_missing_data_on_create" {
  command = plan
  variables {
    context = {
      azure = { resourceGroup = { name = "recipe-test" } }
      resource = {
        name       = "test-secrets"
        properties = {}
      }
    }
  }
  expect_failures = [azurerm_key_vault.vault]
}

run "empty_data_is_valid" {
  command = plan
  variables {
    context = {
      azure = { resourceGroup = { name = "recipe-test" } }
      resource = {
        name       = "test-secrets"
        properties = { data = {} }
      }
    }
  }
}

run "create_preserves_value" {
  command = apply
  assert {
    condition     = azurerm_key_vault_secret.secrets["password"].value == "original-test-value"
    error_message = "A create must preserve the supplied value."
  }
}

run "reject_null_value_on_update" {
  command = plan
  variables {
    context = {
      azure = { resourceGroup = { name = "recipe-test" } }
      resource = {
        name       = "test-secrets"
        properties = { data = { password = { value = null } } }
      }
    }
  }
  expect_failures = [azurerm_key_vault.vault]
}

run "reject_missing_value_on_update" {
  command = plan
  variables {
    context = {
      azure = { resourceGroup = { name = "recipe-test" } }
      resource = {
        name       = "test-secrets"
        properties = { data = { password = {} } }
      }
    }
  }
  expect_failures = [azurerm_key_vault.vault]
}

run "reject_null_data_on_update" {
  command = plan
  variables {
    context = {
      azure = { resourceGroup = { name = "recipe-test" } }
      resource = {
        name       = "test-secrets"
        properties = { data = null }
      }
    }
  }
  expect_failures = [azurerm_key_vault.vault]
}

run "reject_missing_data_on_update" {
  command = plan
  variables {
    context = {
      azure = { resourceGroup = { name = "recipe-test" } }
      resource = {
        name       = "test-secrets"
        properties = {}
      }
    }
  }
  expect_failures = [azurerm_key_vault.vault]
}

run "update_preserves_value" {
  command = apply
  variables {
    context = {
      azure = { resourceGroup = { name = "recipe-test" } }
      resource = {
        name       = "test-secrets"
        properties = { data = { password = { value = "updated-test-value" } } }
      }
    }
  }
  assert {
    condition     = azurerm_key_vault_secret.secrets["password"].value == "updated-test-value"
    error_message = "An update must preserve the supplied value."
  }
}
