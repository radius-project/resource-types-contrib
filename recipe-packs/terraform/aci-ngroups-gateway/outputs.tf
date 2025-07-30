# Output values for the NGroups Gateway Terraform configuration

output "resource_group_name" {
  description = "Name of the resource group"
  value       = data.azurerm_resource_group.current.name
}

output "resource_group_location" {
  description = "Location of the resource group"
  value       = data.azurerm_resource_group.current.location
}

output "subscription_id" {
  description = "Azure subscription ID"
  value       = data.azurerm_client_config.current.subscription_id
}

output "virtual_network_id" {
  description = "ID of the Virtual Network"
  value       = azurerm_virtual_network.vnet.id
}

output "virtual_network_name" {
  description = "Name of the Virtual Network"
  value       = azurerm_virtual_network.vnet.name
}

output "aci_subnet_id" {
  description = "ID of the ACI subnet"
  value       = azurerm_subnet.aci_subnet.id
}

output "app_gateway_subnet_id" {
  description = "ID of the Application Gateway subnet"
  value       = azurerm_subnet.app_gateway_subnet.id
}

output "network_security_group_id" {
  description = "ID of the Network Security Group"
  value       = azurerm_network_security_group.nsg.id
}

output "public_ip_address" {
  description = "Public IP address"
  value       = azurerm_public_ip.public_ip.ip_address
}

output "public_ip_id" {
  description = "ID of the Public IP"
  value       = azurerm_public_ip.public_ip.id
}

output "application_gateway_id" {
  description = "ID of the Application Gateway"
  value       = azurerm_application_gateway.app_gateway.id
}

output "application_gateway_name" {
  description = "Name of the Application Gateway"
  value       = azurerm_application_gateway.app_gateway.name
}

output "backend_address_pool_id" {
  description = "ID of the backend address pool"
  value       = "${azurerm_application_gateway.app_gateway.id}/backendAddressPools/${local.backend_address_pool_name}"
}

output "container_group_profile_name" {
  description = "Name of the container group profile"
  value       = local.container_group_profile_name
}

output "ngroups_name" {
  description = "Name of the NGroups resource"
  value       = local.ngroups_name
}

output "container_group_profile_deployment_id" {
  description = "Deployment ID for container group profile"
  value       = azurerm_resource_group_template_deployment.container_group_profile.id
}

output "ngroups_deployment_id" {
  description = "Deployment ID for NGroups resource"
  value       = azurerm_resource_group_template_deployment.ngroups.id
}

output "application_gateway_frontend_ip" {
  description = "Frontend IP configuration of the Application Gateway"
  value       = azurerm_application_gateway.app_gateway.frontend_ip_configuration[0].name
}

output "application_gateway_backend_pool" {
  description = "Backend address pool name"
  value       = local.backend_address_pool_name
}
