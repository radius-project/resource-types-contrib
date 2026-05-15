terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
  }
}

provider "azurerm" {
  features {}
}

//////////////////////////////////////////
// Common Radius variables
//////////////////////////////////////////

locals {
  resource_name    = var.context.resource.name
  application_name = var.context.application != null ? var.context.application.name : ""
  environment_name = var.context.environment != null ? var.context.environment.name : ""
  namespace        = var.context.runtime.kubernetes.namespace
}

//////////////////////////////////////////
// PostgreSQL variables
//////////////////////////////////////////

locals {
  port        = 5432
  database    = try(var.context.resource.properties.database, "postgres_db")
  secret_name = var.context.resource.properties.secretName
  size_value  = try(var.context.resource.properties.size, "S")

  unique_suffix = substr(md5(var.context.resource.id), 0, 13)
  server_name   = "psql-${local.unique_suffix}"

  sku_map = {
    S = "B_Standard_B1ms"
    M = "GP_Standard_D2s_v3"
    L = "MO_Standard_E2ds_v4"
  }

  sku_name = var.skuName != "" ? var.skuName : local.sku_map[local.size_value]

  tags = {
    "radapp.io/resource"    = local.resource_name
    "radapp.io/application" = local.application_name
    "radapp.io/environment" = local.environment_name
  }
}

//////////////////////////////////////////
// Credentials
//////////////////////////////////////////

data "kubernetes_secret" "db_credentials" {
  metadata {
    name      = local.secret_name
    namespace = local.namespace
  }
}

//////////////////////////////////////////
// Resource Group
//////////////////////////////////////////

data "azurerm_resource_group" "rg" {
  name = var.context.azure.resourceGroup.name
}

//////////////////////////////////////////
// PostgreSQL Flexible Server
//////////////////////////////////////////

resource "azurerm_postgresql_flexible_server" "postgres" {
  name                          = local.server_name
  resource_group_name           = data.azurerm_resource_group.rg.name
  location                      = data.azurerm_resource_group.rg.location
  version                       = var.postgresqlVersion
  administrator_login           = data.kubernetes_secret.db_credentials.data["USERNAME"]
  administrator_password        = data.kubernetes_secret.db_credentials.data["PASSWORD"]
  sku_name                      = local.sku_name
  storage_mb                    = var.storageMb
  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = true

  tags = local.tags
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure_services" {
  name             = "AllowAllAzureServices"
  server_id        = azurerm_postgresql_flexible_server.postgres.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_database" "db" {
  name      = local.database
  server_id = azurerm_postgresql_flexible_server.postgres.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

//////////////////////////////////////////
// Output
//////////////////////////////////////////

output "result" {
  value = {
    resources = [azurerm_postgresql_flexible_server.postgres.id]
    values = {
      host     = azurerm_postgresql_flexible_server.postgres.fqdn
      port     = local.port
      database = azurerm_postgresql_flexible_server_database.db.name
    }
  }
  sensitive = true
}
