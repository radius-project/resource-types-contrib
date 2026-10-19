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
}

run "invalid_create" {
  command = plan
}
