output "container_group_profile_id" {
  description = "The ID of the Container Group Profile"
  value       = jsondecode(azurerm_resource_group_template_deployment.container_group_profile.output_content).containerGroupProfileId.value
}

output "ngroups_id" {
  description = "The ID of the NGroups resource"
  value       = jsondecode(azurerm_resource_group_template_deployment.ngroups.output_content).nGroupId.value
}

output "resource_group_name" {
  description = "The name of the resource group"
  value       = data.azurerm_resource_group.main.name
}

output "deployment_names" {
  description = "Names of the ARM template deployments"
  value = {
    container_group_profile = azurerm_resource_group_template_deployment.container_group_profile.name
    ngroups                = azurerm_resource_group_template_deployment.ngroups.name
  }
}
