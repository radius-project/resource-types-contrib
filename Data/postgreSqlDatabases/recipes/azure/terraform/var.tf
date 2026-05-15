variable "context" {
  description = "This variable contains Radius Recipe context."
  type        = any
  default     = null
}

variable "skuName" {
  description = "The SKU name for the PostgreSQL Flexible Server. Overrides the size property from the resource if set."
  type        = string
  default     = ""
}

variable "storageMb" {
  description = "Storage size in MB for the PostgreSQL Flexible Server."
  type        = number
  default     = 32768
}

variable "postgresqlVersion" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}
