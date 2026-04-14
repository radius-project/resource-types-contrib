variable "context" {
  description = "This variable contains Radius recipe context."
  type        = any
}

variable "ghcr_server" {
  description = "Registry server (e.g., ghcr.io). Set via recipe parameters when registering the recipe."
  type        = string
  default     = "ghcr.io"
}

variable "ghcr_username" {
  description = "Registry username. Set via recipe parameters when registering the recipe."
  type        = string
  default     = ""
}

variable "ghcr_token" {
  description = "Registry token/PAT. Set via recipe parameters when registering the recipe."
  type        = string
  default     = ""
  sensitive   = true
}
