variable "context" {
  description = "Radius recipe context. Carries resource properties, environment, and runtime info."
  type        = any
  default     = null
}

variable "registry" {
  description = "Default registry path (e.g. `ghcr.io/myorg`) into which images are pushed. May be overridden per-resource via `properties.registry`."
  type        = string
}
