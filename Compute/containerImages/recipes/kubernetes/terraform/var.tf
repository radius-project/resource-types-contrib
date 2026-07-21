variable "context" {
  description = "Radius recipe context. Carries resource properties, environment, and runtime info."
  type        = any
  default     = null
}

variable "registry" {
  description = "Default registry path (e.g. `ghcr.io/myorg`) into which images are pushed."
  type        = string
}

variable "registrySecretName" {
  description = "Name of the Kubernetes Secret holding the registry credentials. Supplied by the platform engineer as a recipe-pack parameter, typically as `ghcrCreds.name` referencing an application-scoped `Radius.Security/secrets` resource whose recipe materializes a same-named Secret in the recipe runtime namespace. The Secret must contain string keys `username` and `password`. Leave empty for an unauthenticated registry."
  type        = string
  default     = ""
}
