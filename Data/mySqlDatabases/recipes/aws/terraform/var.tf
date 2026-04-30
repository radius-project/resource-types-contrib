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
  description = "The RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "allocatedStorage" {
  description = "Initial allocated storage in GB."
  type        = number
  default     = 20
}
