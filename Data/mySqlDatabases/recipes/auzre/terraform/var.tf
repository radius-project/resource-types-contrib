variable "context" {
  description = "This variable contains Radius Recipe context."
  type        = any
  default     = null
}

variable "azure_subscription_id" {
  description = "Azure subscription ID for the azurerm provider."
  type        = string
}

variable "resourceGroupName" {
  description = "Name of the Azure resource group where the MySQL server will be created."
  type        = string
}

variable "location" {
  description = "Azure region for the MySQL server (e.g. eastus, westus2)."
  type        = string
  default     = "eastus"
}

variable "skuName" {
  description = "The SKU name for the MySQL Flexible Server (e.g. B_Standard_B1ms, GP_Standard_D2ds_v4)."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "storageSizeGb" {
  description = "Storage size in GB for the MySQL server."
  type        = number
  default     = 20
}
