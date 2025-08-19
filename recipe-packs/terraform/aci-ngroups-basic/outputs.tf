# Output values for the Terraform configuration

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

output "container_group_profile_name" {
  description = "Name of the container group profile"
  value       = local.cg_profile_name
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
