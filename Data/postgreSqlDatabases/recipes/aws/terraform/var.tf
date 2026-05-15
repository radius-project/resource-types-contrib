variable "context" {
  description = "This variable contains Radius Recipe context."
  type        = any
  default     = null
}

variable "vpcId" {
  description = "ID of the VPC where the RDS instance will be created."
  type        = string
}

variable "subnetIds" {
  description = "JSON-encoded list of private subnet IDs for the DB subnet group (at least two AZs recommended)."
  type        = string
}

variable "instanceClass" {
  description = "The RDS instance class. Overrides the size property from the resource if set."
  type        = string
  default     = ""
}

variable "allocatedStorage" {
  description = "Initial allocated storage in GB."
  type        = number
  default     = 20
}

variable "postgresqlVersion" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}
