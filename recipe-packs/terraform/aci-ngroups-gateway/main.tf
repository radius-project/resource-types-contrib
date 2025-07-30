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
  api_version                        = var.api_version
  ngroups_name                      = var.ngroups_name_param
  container_group_profile_name      = var.container_group_profile_name
  application_gateway_name          = var.application_gateway_name
  public_ip_name                    = var.public_ip_name
  backend_address_pool_name         = var.backend_address_pool_name
  vnet_name                         = var.vnet_name
  network_security_group_name       = var.network_security_group_name
  desired_count                     = var.desired_count
  maintain_desired_count            = var.maintain_desired_count
  zones                             = var.zones
  vnet_address_prefix               = var.vnet_address_prefix
  aci_subnet_address_prefix         = var.aci_subnet_address_prefix
  app_gateway_subnet_address_prefix = var.app_gateway_subnet_address_prefix
  aci_subnet_name                   = var.aci_subnet_name
  app_gateway_subnet_name           = var.app_gateway_subnet_name
  ddos_protection_plan_name         = var.ddos_protection_plan_name
  
  description                       = "This ARM template is an example template of using an App Gateway with a NGroup."
  resource_prefix                   = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${data.azurerm_resource_group.current.name}/providers/"
  application_gateway_api_version   = "2022-09-01"
  prefix_cg                         = "cg-lin100-regional-ag-"
}

# Network Security Group
resource "azurerm_network_security_group" "nsg" {
  name                = local.network_security_group_name
  location            = data.azurerm_resource_group.current.location
  resource_group_name = data.azurerm_resource_group.current.name

  security_rule {
    name                       = "AppGatewayV2ProbeInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
    description                = "Allow traffic from GatewayManager. This rule is needed for application gateway probes to work."
  }

  security_rule {
    name                       = "AllowHTTPInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
    description                = "Allow Internet traffic on port 80"
  }

  security_rule {
    name                       = "AllowPublicIPAddress"
    priority                   = 111
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = azurerm_public_ip.public_ip.ip_address
    description                = "Allow traffic from public ip address"
  }

  security_rule {
    name                       = "AllowVirtualNetworkInbound"
    priority                   = 112
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
    description                = "Allow Internet traffic to Virtual network"
  }
}

# Virtual Network
resource "azurerm_virtual_network" "vnet" {
  name                = local.vnet_name
  location            = data.azurerm_resource_group.current.location
  resource_group_name = data.azurerm_resource_group.current.name
  address_space       = [local.vnet_address_prefix]

  depends_on = [azurerm_network_security_group.nsg]
}

# ACI Subnet
resource "azurerm_subnet" "aci_subnet" {
  name                 = local.aci_subnet_name
  resource_group_name  = data.azurerm_resource_group.current.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [local.aci_subnet_address_prefix]

  delegation {
    name = "ACIDelegationService"

    service_delegation {
      name = "Microsoft.ContainerInstance/containerGroups"
    }
  }

  private_endpoint_network_policies_enabled     = false
  private_link_service_network_policies_enabled = true

  depends_on = [azurerm_virtual_network.vnet]
}

# Application Gateway Subnet
resource "azurerm_subnet" "app_gateway_subnet" {
  name                 = local.app_gateway_subnet_name
  resource_group_name  = data.azurerm_resource_group.current.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [local.app_gateway_subnet_address_prefix]

  private_endpoint_network_policies_enabled     = false
  private_link_service_network_policies_enabled = true

  depends_on = [azurerm_virtual_network.vnet]
}

# Associate NSG with ACI Subnet
resource "azurerm_subnet_network_security_group_association" "aci_subnet_nsg" {
  subnet_id                 = azurerm_subnet.aci_subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# Associate NSG with Application Gateway Subnet
resource "azurerm_subnet_network_security_group_association" "app_gateway_subnet_nsg" {
  subnet_id                 = azurerm_subnet.app_gateway_subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# Public IP for Application Gateway
resource "azurerm_public_ip" "public_ip" {
  name                    = local.public_ip_name
  location                = data.azurerm_resource_group.current.location
  resource_group_name     = data.azurerm_resource_group.current.name
  allocation_method       = "Static"
  sku                     = "Standard"
  sku_tier                = "Regional"
  ip_version              = "IPv4"
  idle_timeout_in_minutes = 5

  ddos_protection_mode = "VirtualNetworkInherited"
}

# Application Gateway
resource "azurerm_application_gateway" "app_gateway" {
  name                = local.application_gateway_name
  location            = data.azurerm_resource_group.current.location
  resource_group_name = data.azurerm_resource_group.current.name

  sku {
    name = "Standard_v2"
    tier = "Standard_v2"
  }

  autoscale_configuration {
    min_capacity = 0
    max_capacity = 3
  }

  gateway_ip_configuration {
    name      = "appGatewayIpConfig"
    subnet_id = azurerm_subnet.app_gateway_subnet.id
  }

  frontend_port {
    name = "port_80"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "appGwPublicFrontendIpIPv4"
    public_ip_address_id = azurerm_public_ip.public_ip.id
  }

  backend_address_pool {
    name = local.backend_address_pool_name
  }

  backend_http_settings {
    name                  = "${local.application_gateway_name}-be-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
    probe_name            = "healthprobe"
  }

  http_listener {
    name                           = "${local.application_gateway_name}-listener"
    frontend_ip_configuration_name = "appGwPublicFrontendIpIPv4"
    frontend_port_name             = "port_80"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "${local.application_gateway_name}-routerule"
    rule_type                  = "Basic"
    priority                   = 1
    http_listener_name         = "${local.application_gateway_name}-listener"
    backend_address_pool_name  = local.backend_address_pool_name
    backend_http_settings_name = "${local.application_gateway_name}-be-settings"
  }

  probe {
    name                = "healthprobe"
    protocol            = "Http"
    path                = "/"
    host                = "127.0.0.1"
    interval            = 3600
    timeout             = 3600
    unhealthy_threshold = 3
  }

  depends_on = [
    azurerm_subnet.app_gateway_subnet,
    azurerm_public_ip.public_ip
  ]
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
      containerGroupProfileName = local.container_group_profile_name
      apiVersion               = local.api_version
    }
    resources = [
      {
        apiVersion = local.api_version
        type       = "Microsoft.ContainerInstance/containerGroupProfiles"
        name       = local.container_group_profile_name
        location   = data.azurerm_resource_group.current.location
        properties = {
          sku = "Standard"
          containers = [
            {
              name = "web"
              properties = {
                image = var.container_image
                ports = [
                  {
                    protocol = "TCP"
                    port     = var.container_port
                  }
                ]
                resources = {
                  requests = {
                    memoryInGB = var.memory_gb
                    cpu        = var.cpu_cores
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
                port     = var.container_port
              }
            ]
            type = "Private"
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
    azurerm_resource_group_template_deployment.container_group_profile,
    azurerm_application_gateway.app_gateway,
    azurerm_virtual_network.vnet
  ]

  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters     = {}
    variables = {
      containerGroupProfileName = local.container_group_profile_name
      nGroupsNameParam         = local.ngroups_name
      applicationGatewayName   = local.application_gateway_name
      vnetName                 = local.vnet_name
      aciSubnetName           = local.aci_subnet_name
      backendAddressPoolName  = local.backend_address_pool_name
      apiVersion              = local.api_version
      desiredCount            = local.desired_count
      maintainDesiredCount    = local.maintain_desired_count
      prefixCG                = local.prefix_cg
      resourcePrefix          = local.resource_prefix
    }
    resources = [
      {
        apiVersion = local.api_version
        type       = "Microsoft.ContainerInstance/NGroups"
        name       = local.ngroups_name
        location   = data.azurerm_resource_group.current.location
        dependsOn = [
          "Microsoft.ContainerInstance/containerGroupProfiles/${local.container_group_profile_name}"
        ]
        properties = {
          elasticProfile = {
            desiredCount         = local.desired_count
            maintainDesiredCount = local.maintain_desired_count
            containerGroupNamingPolicy = {
              guidNamingPolicy = {
                prefix = local.prefix_cg
              }
            }
          }
          containerGroupProfiles = [
            {
              resource = {
                id = "${local.resource_prefix}Microsoft.ContainerInstance/containerGroupProfiles/${local.container_group_profile_name}"
              }
              containerGroupProperties = {
                subnetIds = [
                  {
                    id   = azurerm_subnet.aci_subnet.id
                    name = local.aci_subnet_name
                  }
                ]
              }
              networkProfile = {
                applicationGateway = {
                  resource = {
                    id = azurerm_application_gateway.app_gateway.id
                  }
                  backendAddressPools = [
                    {
                      resource = {
                        id = "${azurerm_application_gateway.app_gateway.id}/backendAddressPools/${local.backend_address_pool_name}"
                      }
                    }
                  ]
                }
              }
            }
          ]
        }
        zones = local.zones
        tags = {
          "cirrusTestScenario"    = "lin-100.regional.appgateway"
          "reprovision.enabled"   = "true"
        }
      }
    ]
  })
}
