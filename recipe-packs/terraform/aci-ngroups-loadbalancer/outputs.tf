# Output values for the ACI NGroups LoadBalancer Terraform configuration

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

output "subnet_id" {
  description = "ID of the subnet"
  value       = azurerm_subnet.subnet.id
}

output "network_security_group_id" {
  description = "ID of the Network Security Group"
  value       = azurerm_network_security_group.nsg.id
}

output "ddos_protection_plan_id" {
  description = "ID of the DDoS Protection Plan"
  value       = azurerm_network_ddos_protection_plan.ddos_plan.id
}

output "nat_gateway_id" {
  description = "ID of the NAT Gateway"
  value       = azurerm_nat_gateway.nat_gateway.id
}

output "inbound_public_ip_address" {
  description = "Inbound public IP address"
  value       = azurerm_public_ip.inbound_public_ip.ip_address
}

output "inbound_public_ip_fqdn" {
  description = "Fully qualified domain name of the inbound public IP"
  value       = azurerm_public_ip.inbound_public_ip.fqdn
}

output "outbound_public_ip_address" {
  description = "Outbound public IP address"
  value       = azurerm_public_ip.outbound_public_ip.ip_address
}

output "load_balancer_id" {
  description = "ID of the Load Balancer"
  value       = azurerm_lb.load_balancer.id
}

output "load_balancer_frontend_ip_id" {
  description = "ID of the Load Balancer frontend IP configuration"
  value       = azurerm_lb.load_balancer.frontend_ip_configuration[0].id
}

output "backend_address_pool_id" {
  description = "ID of the backend address pool"
  value       = azurerm_lb_backend_address_pool.backend_pool.id
}

output "health_probe_id" {
  description = "ID of the health probe"
  value       = azurerm_lb_probe.health_probe.id
}

output "http_rule_id" {
  description = "ID of the HTTP load balancing rule"
  value       = azurerm_lb_rule.http_rule.id
}

output "inbound_nat_rule_id" {
  description = "ID of the inbound NAT rule"
  value       = azurerm_lb_nat_rule.inbound_nat_rule.id
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

output "load_balancer_frontend_ip" {
  description = "Frontend IP configuration of the Load Balancer"
  value       = local.frontend_ip_name
}

output "backend_pool_name" {
  description = "Backend address pool name"
  value       = local.backend_address_pool_name
}
