variable "context" {
  description = "This variable contains Radius recipe context."
  type        = any
  default     = null
}

variable "registry_server" {
  description = "Registry server address for authentication. Defaults to ghcr.io."
  type        = string
  default     = "ghcr.io"
}
