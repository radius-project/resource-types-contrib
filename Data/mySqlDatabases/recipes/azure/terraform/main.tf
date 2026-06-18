terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
  use_oidc        = true
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
// Unique server name
//////////////////////////////////////////

# Generates a per-deployment random suffix so re-deploys after a server has
# been deleted (and is in Azure's 7-day soft-delete window) don't collide on
# the globally-reserved server name. The value is stable in Terraform state,
# so re-applies with the same state are idempotent.
resource "random_id" "server_suffix" {
  byte_length = 7
}

//////////////////////////////////////////
// MySQL variables
//////////////////////////////////////////

locals {
  port        = 3306
  database    = try(var.context.resource.properties.database, "mysql_db")
  secret_name = var.context.resource.properties.secretName
  # Azure MySQL Flexible Server accepts only specific version strings.
  # Map common shorthand values to valid versions.
  version = lookup(
    { "8.0" = "8.0.21", "8" = "8.0.21", "5" = "5.7" },
    try(var.context.resource.properties.version, "8.0.21"),
    try(var.context.resource.properties.version, "8.0.21")
  )

  unique_suffix = random_id.server_suffix.hex

  # Azure MySQL server name: lowercase alphanumeric and hyphens, 3-63 chars
  sanitized_server_name = "mysql-${local.unique_suffix}"

  # Database name: alphanumeric and underscores only
  sanitized_database = replace(local.database, "/[^0-9A-Za-z_]/", "_")

  tags = {
    "radapp.io-resource"    = local.resource_name
    "radapp.io-application" = local.application_name
    "radapp.io-environment" = local.environment_name
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
// Azure MySQL Flexible Server
//////////////////////////////////////////

resource "azurerm_mysql_flexible_server" "mysql" {
  name                = local.sanitized_server_name
  resource_group_name = var.resourceGroupName
  location            = var.location

  administrator_login    = try(data.kubernetes_secret.db_credentials.data["USERNAME"], "")
  administrator_password = try(data.kubernetes_secret.db_credentials.data["PASSWORD"], "")

  sku_name = var.skuName
  version  = local.version

  backup_retention_days = 7

  storage {
    size_gb = var.storageSizeGb
  }

  tags = local.tags
}

//////////////////////////////////////////
// Firewall rule — allow Azure services
//////////////////////////////////////////

resource "azurerm_mysql_flexible_server_firewall_rule" "allow_azure" {
  name                = "AllowAzureServices"
  resource_group_name = var.resourceGroupName
  server_name         = azurerm_mysql_flexible_server.mysql.name
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}

//////////////////////////////////////////
// Database
//////////////////////////////////////////

resource "azurerm_mysql_flexible_database" "db" {
  name                = local.sanitized_database
  resource_group_name = var.resourceGroupName
  server_name         = azurerm_mysql_flexible_server.mysql.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

//////////////////////////////////////////
// Output
//////////////////////////////////////////

output "result" {
  value = {
    resources = []
    values = {
      host     = azurerm_mysql_flexible_server.mysql.fqdn
      port     = local.port
      database = local.sanitized_database
    }
  }
}