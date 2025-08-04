# Configure the Azure Provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
  }
}

# Configure the Microsoft Azure Provider
provider "azurerm" {
  features {}
}

# Data source to get current resource group
data "azurerm_resource_group" "current" {
  name = var.resource_group_name
}

# Data source to get current subscription
data "azurerm_client_config" "current" {}

# Local variables
locals {
  cg_profile_name = "cgp_1"
  ngroups_name    = "ngroup_lin1_basic"
  api_version     = "2024-09-01-preview"
  desired_count   = 1
  prefix_cg       = "cg-lin1-basic-"
  resource_prefix = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${data.azurerm_resource_group.current.name}/providers/"
}

# Template deployment for Container Group Profile (using ARM template within Terraform)
resource "azurerm_resource_group_template_deployment" "container_group_profile" {
  name                = "cgp-deployment"
  resource_group_name = data.azurerm_resource_group.current.name
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters     = {}
    variables = {
      cgProfileName = local.cg_profile_name
      apiVersion    = local.api_version
    }
    resources = [
      {
        apiVersion = local.api_version
        type       = "Microsoft.ContainerInstance/containerGroupProfiles"
        name       = local.cg_profile_name
        location   = data.azurerm_resource_group.current.location
        properties = {
          sku = "Standard"
          containers = [
            {
              name = "aci-helloworld"
              properties = {
                image = "mcr.microsoft.com/azuredocs/aci-helloworld@sha256:565dba8ce20ca1a311c2d9485089d7ddc935dd50140510050345a1b0ea4ffa6e"
                ports = [
                  {
                    protocol = "TCP"
                    port     = 80
                  }
                ]
                resources = {
                  requests = {
                    memoryInGB = 1.0
                    cpu        = 1.0
                  }
                }
              }
            }
          ]
          restartPolicy = "Always"
          ipAddress = {
            ports = [
              {
                protocol = "TCP"
                port     = 80
              }
            ]
            type = "Public"
          }
          osType = "Linux"
        }
      }
    ]
  })
}

# Template deployment for NGroups
resource "azurerm_resource_group_template_deployment" "ngroups" {
  name                = "ngroups-deployment"
  resource_group_name = data.azurerm_resource_group.current.name
  deployment_mode     = "Incremental"

  depends_on = [
    azurerm_resource_group_template_deployment.container_group_profile
  ]

  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters     = {}
    variables = {
      cgProfileName   = local.cg_profile_name
      nGroupsName     = local.ngroups_name
      apiVersion      = local.api_version
      desiredCount    = local.desired_count
      prefixCG        = local.prefix_cg
      resourcePrefix  = local.resource_prefix
    }
    resources = [
      {
        apiVersion = local.api_version
        type       = "Microsoft.ContainerInstance/NGroups"
        name       = local.ngroups_name
        location   = data.azurerm_resource_group.current.location
        dependsOn = [
          "Microsoft.ContainerInstance/containerGroupProfiles/${local.cg_profile_name}"
        ]
        properties = {
          elasticProfile = {
            desiredCount = local.desired_count
            containerGroupNamingPolicy = {
              guidNamingPolicy = {
                prefix = local.prefix_cg
              }
            }
          }
          containerGroupProfiles = [
            {
              resource = {
                id = "${local.resource_prefix}Microsoft.ContainerInstance/containerGroupProfiles/${local.cg_profile_name}"
              }
            }
          ]
        }
        tags = {
          cirrusTestScenario = "lin-1.basic"
        }
      }
    ]
  })
}
