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
  api_version                     = var.api_version
  ngroups_name                    = var.ngroups_param_name
  container_group_profile_name    = var.container_group_profile_name
  load_balancer_name              = var.load_balancer_name
  backend_address_pool_name       = var.backend_address_pool_name
  vnet_name                       = var.vnet_name
  subnet_name                     = var.subnet_name
  network_security_group_name     = var.network_security_group_name
  inbound_public_ip_name          = var.inbound_public_ip_name
  outbound_public_ip_name         = var.outbound_public_ip_name
  outbound_public_ip_prefix_name  = var.outbound_public_ip_prefix_name
  nat_gateway_name                = var.nat_gateway_name
  frontend_ip_name                = var.frontend_ip_name
  http_rule_name                  = var.http_rule_name
  health_probe_name               = var.health_probe_name
  vnet_address_prefix             = var.vnet_address_prefix
  subnet_address_prefix           = var.subnet_address_prefix
  desired_count                   = var.desired_count
  zones                           = var.zones
  maintain_desired_count          = var.maintain_desired_count
  domain_name_label               = var.domain_name_label
  inbound_nat_rule_name           = var.inbound_nat_rule_name
  
  description                     = "This ARM template is an example template to test the load balancer integration with NGroups."
  cg_profile_name                 = var.container_group_profile_name
  prefix_cg                       = "cg-lin100-regional-lb-"
  resource_prefix                 = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${data.azurerm_resource_group.current.name}/providers/"
  load_balancer_api_version       = "2022-07-01"
  vnet_api_version                = "2022-07-01"
  public_ip_version               = "2022-07-01"
  ddos_protection_plan_name       = "ddosProtectionPlan"
}

# DDoS Protection Plan
resource "azurerm_network_ddos_protection_plan" "ddos_plan" {
  name                = local.ddos_protection_plan_name
  location            = data.azurerm_resource_group.current.location
  resource_group_name = data.azurerm_resource_group.current.name
}

# Network Security Group
resource "azurerm_network_security_group" "nsg" {
  name                = local.network_security_group_name
  location            = data.azurerm_resource_group.current.location
  resource_group_name = data.azurerm_resource_group.current.name

  security_rule {
    name                         = "AllowHTTPInbound"
    priority                     = 100
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "*"
    source_port_range            = "*"
    destination_port_ranges      = ["80-331"]
    source_address_prefix        = "Internet"
    destination_address_prefix   = "*"
    description                  = "Allow Internet traffic on port range"
  }
}

# Outbound Public IP for NAT Gateway
resource "azurerm_public_ip" "outbound_public_ip" {
  name                = local.outbound_public_ip_name
  location            = data.azurerm_resource_group.current.location
  resource_group_name = data.azurerm_resource_group.current.name
  allocation_method   = "Static"
  sku                 = "Standard"
  sku_tier            = "Regional"
  ip_version          = "IPv4"
  idle_timeout_in_minutes = 4
}

# Inbound Public IP for Load Balancer
resource "azurerm_public_ip" "inbound_public_ip" {
  name                = local.inbound_public_ip_name
  location            = data.azurerm_resource_group.current.location
  resource_group_name = data.azurerm_resource_group.current.name
  allocation_method   = "Static"
  sku                 = "Standard"
  sku_tier            = "Regional"
  ip_version          = "IPv4"
  idle_timeout_in_minutes = 4
  domain_name_label   = local.domain_name_label
}

# NAT Gateway
resource "azurerm_nat_gateway" "nat_gateway" {
  name                    = local.nat_gateway_name
  location                = data.azurerm_resource_group.current.location
  resource_group_name     = data.azurerm_resource_group.current.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 4
}

# Associate NAT Gateway with Outbound Public IP
resource "azurerm_nat_gateway_public_ip_association" "nat_gateway_ip" {
  nat_gateway_id       = azurerm_nat_gateway.nat_gateway.id
  public_ip_address_id = azurerm_public_ip.outbound_public_ip.id
}

# Virtual Network
resource "azurerm_virtual_network" "vnet" {
  name                = local.vnet_name
  location            = data.azurerm_resource_group.current.location
  resource_group_name = data.azurerm_resource_group.current.name
  address_space       = [local.vnet_address_prefix]

  ddos_protection_plan {
    id     = azurerm_network_ddos_protection_plan.ddos_plan.id
    enable = true
  }

  depends_on = [
    azurerm_network_security_group.nsg,
    azurerm_nat_gateway.nat_gateway
  ]
}

# Subnet
resource "azurerm_subnet" "subnet" {
  name                 = local.subnet_name
  resource_group_name  = data.azurerm_resource_group.current.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [local.subnet_address_prefix]

  delegation {
    name = "Microsoft.ContainerInstance.containerGroups"

    service_delegation {
      name = "Microsoft.ContainerInstance/containerGroups"
    }
  }

  private_endpoint_network_policies_enabled     = false
  private_link_service_network_policies_enabled = true

  depends_on = [azurerm_virtual_network.vnet]
}

# Associate NSG with Subnet
resource "azurerm_subnet_network_security_group_association" "subnet_nsg" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# Associate NAT Gateway with Subnet
resource "azurerm_subnet_nat_gateway_association" "subnet_nat" {
  subnet_id      = azurerm_subnet.subnet.id
  nat_gateway_id = azurerm_nat_gateway.nat_gateway.id
}

# Load Balancer
resource "azurerm_lb" "load_balancer" {
  name                = local.load_balancer_name
  location            = data.azurerm_resource_group.current.location
  resource_group_name = data.azurerm_resource_group.current.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = local.frontend_ip_name
    public_ip_address_id = azurerm_public_ip.inbound_public_ip.id
  }

  depends_on = [
    azurerm_public_ip.inbound_public_ip,
    azurerm_virtual_network.vnet
  ]
}

# Load Balancer Backend Address Pool
resource "azurerm_lb_backend_address_pool" "backend_pool" {
  loadbalancer_id = azurerm_lb.load_balancer.id
  name            = local.backend_address_pool_name
}

# Load Balancer Health Probe
resource "azurerm_lb_probe" "health_probe" {
  loadbalancer_id = azurerm_lb.load_balancer.id
  name            = local.health_probe_name
  protocol        = "Tcp"
  port            = 80
  interval_in_seconds         = 5
  number_of_probes           = 2
  probe_threshold            = 1
}

# Load Balancer Rule
resource "azurerm_lb_rule" "http_rule" {
  loadbalancer_id                = azurerm_lb.load_balancer.id
  name                          = local.http_rule_name
  protocol                      = "Tcp"
  frontend_port                 = 80
  backend_port                  = 80
  frontend_ip_configuration_name = local.frontend_ip_name
  backend_address_pool_ids      = [azurerm_lb_backend_address_pool.backend_pool.id]
  probe_id                      = azurerm_lb_probe.health_probe.id
  enable_floating_ip            = false
  idle_timeout_in_minutes       = 15
  enable_tcp_reset              = true
  load_distribution             = "Default"
  disable_outbound_snat         = false
}

# Load Balancer Inbound NAT Rule
resource "azurerm_lb_nat_rule" "inbound_nat_rule" {
  resource_group_name            = data.azurerm_resource_group.current.name
  loadbalancer_id                = azurerm_lb.load_balancer.id
  name                          = local.inbound_nat_rule_name
  protocol                      = "Tcp"
  frontend_port_start           = 81
  frontend_port_end             = 331
  backend_port                  = 80
  frontend_ip_configuration_name = local.frontend_ip_name
  enable_floating_ip            = false
  enable_tcp_reset              = false
  idle_timeout_in_minutes       = 4
  backend_address_pool_id       = azurerm_lb_backend_address_pool.backend_pool.id
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
    azurerm_lb.load_balancer,
    azurerm_virtual_network.vnet
  ]

  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters     = {}
    variables = {
      cgProfileName            = local.cg_profile_name
      nGroupsName             = local.ngroups_name
      loadBalancerName        = local.load_balancer_name
      vnetName                = local.vnet_name
      subnetName              = local.subnet_name
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
          "Microsoft.ContainerInstance/containerGroupProfiles/${local.cg_profile_name}"
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
                id = "${local.resource_prefix}Microsoft.ContainerInstance/containerGroupProfiles/${local.cg_profile_name}"
              }
              containerGroupProperties = {
                subnetIds = [
                  {
                    id   = azurerm_subnet.subnet.id
                    name = local.subnet_name
                  }
                ]
              }
              networkProfile = {
                loadBalancer = {
                  backendAddressPools = [
                    {
                      resource = {
                        id = azurerm_lb_backend_address_pool.backend_pool.id
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
          "cirrusTestScenario"    = "lin-100.regional.loadbalancer"
          "reprovision.enabled"   = "true"
        }
      }
    ]
  })
}
