variable "context" {
  description = "This variable contains Radius recipe context."
  type        = any
  default     = null
}

variable "daprServiceAccountName" {
  description = "Name of the Kubernetes ServiceAccount of the Dapr apps that read secrets. The Recipe gives this ServiceAccount read access to the secrets in allowedSecrets only. The Kubernetes Container Recipes in this repository use the default ServiceAccount."
  type        = string
  default     = "default"
}
