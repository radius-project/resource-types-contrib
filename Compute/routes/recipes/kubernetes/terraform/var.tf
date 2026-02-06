variable "context" {
  description = "This variable contains Radius recipe context."
  type        = any
}

variable "gateway_name" {
  description = "Name of the Gateway resource to attach routes to. Must be provided by the user."
  type        = string
}

variable "gateway_namespace" {
  description = "Namespace where the Gateway resource is located. Must be provided by the user."
  type        = string
}