variable "context" {
  description = "This variable contains Radius recipe context."
  type        = any
  default     = null
}

variable "gateway_name" {
  description = "Name of the Gateway resource to attach routes to."
  type        = string
  default     = "radius"
}

variable "gateway_namespace" {
  description = "Namespace where the Gateway resource is located."
  type        = string
  default     = "radius-system"
}
