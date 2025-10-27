terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Data source for current resource group
data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

# Data source for current client configuration
data "azurerm_client_config" "current" {}

# Container Group Profile ARM Template Deployment
resource "azurerm_resource_group_template_deployment" "container_group_profile" {
  name                = "cgp-confidential-deployment"
  resource_group_name = data.azurerm_resource_group.main.name
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters = {
      cgProfileName = {
        type = "string"
      }
      apiVersion = {
        type = "string"
      }
    }
    resources = [
      {
        apiVersion = "[parameters('apiVersion')]"
        type       = "Microsoft.ContainerInstance/containerGroupProfiles"
        name       = "[parameters('cgProfileName')]"
        location   = "[resourceGroup().location]"
        properties = {
          sku = "Confidential"
          confidentialComputeProperties = {
            ccePolicy = ""
          }
          containers = [
            {
              name = "aci-helloworld"
              properties = {
                image = var.container_image
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
    outputs = {
      containerGroupProfileId = {
        type  = "string"
        value = "[resourceId('Microsoft.ContainerInstance/containerGroupProfiles', parameters('cgProfileName'))]"
      }
    }
  })

  parameters_content = jsonencode({
    cgProfileName = {
      value = var.container_group_profile_name
    }
    apiVersion = {
      value = var.api_version
    }
  })

  tags = var.tags
}

# NGroups ARM Template Deployment
resource "azurerm_resource_group_template_deployment" "ngroups" {
  name                = "ngroups-confidential-deployment"
  resource_group_name = data.azurerm_resource_group.main.name
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters = {
      nGroupsName = {
        type = "string"
      }
      cgProfileName = {
        type = "string"
      }
      apiVersion = {
        type = "string"
      }
      desiredCount = {
        type = "int"
      }
      prefixCG = {
        type = "string"
      }
      resourcePrefix = {
        type = "string"
      }
    }
    resources = [
      {
        apiVersion = "[parameters('apiVersion')]"
        type       = "Microsoft.ContainerInstance/NGroups"
        name       = "[parameters('nGroupsName')]"
        location   = "[resourceGroup().location]"
        dependsOn = [
          "[concat('Microsoft.ContainerInstance/containerGroupProfiles/', parameters('cgProfileName'))]"
        ]
        properties = {
          elasticProfile = {
            desiredCount = "[parameters('desiredCount')]"
            containerGroupNamingPolicy = {
              guidNamingPolicy = {
                prefix = "[parameters('prefixCG')]"
              }
            }
          }
          containerGroupProfiles = [
            {
              resource = {
                id = "[concat(parameters('resourcePrefix'), 'Microsoft.ContainerInstance/containerGroupProfiles/', parameters('cgProfileName'))]"
              }
            }
          ]
        }
        tags = {
          "cirrusTestScenario" = "confidential-1.basic"
        }
      }
    ]
    outputs = {
      nGroupId = {
        type  = "string"
        value = "[resourceId('Microsoft.ContainerInstance/NGroups', parameters('nGroupsName'))]"
      }
    }
  })

  parameters_content = jsonencode({
    nGroupsName = {
      value = var.ngroups_name
    }
    cgProfileName = {
      value = var.container_group_profile_name
    }
    apiVersion = {
      value = var.api_version
    }
    desiredCount = {
      value = var.desired_count
    }
    prefixCG = {
      value = var.prefix_cg
    }
    resourcePrefix = {
      value = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${data.azurerm_resource_group.main.name}/providers/"
    }
  })

  tags = var.tags

  depends_on = [
    azurerm_resource_group_template_deployment.container_group_profile
  ]
}
