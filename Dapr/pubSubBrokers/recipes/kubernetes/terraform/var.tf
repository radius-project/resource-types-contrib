variable "context" {
  description = "This variable contains Radius recipe context."
  type        = any
  default     = null
}

variable "daprAllowedAppIds" {
  description = "Platform allowlist of Dapr app IDs. Resource scopes may narrow this list but cannot extend it. If empty, the resource must set nonempty scopes."
  type        = list(string)
  default     = []
  nullable    = false
  validation {
    condition     = length(distinct(var.daprAllowedAppIds)) == length(var.daprAllowedAppIds) && alltrue([for id in var.daprAllowedAppIds : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", id)) && length(id) <= 63])
    error_message = "daprAllowedAppIds must contain unique IDs of 1 to 63 lowercase letters, digits, or hyphens, with a letter or digit at each end."
  }
}

variable "redisImageTag" {
  description = "Tag of the redis container image for the default pub/sub broker."
  type        = string
  default     = "7-alpine"
}

variable "redisMemoryRequest" {
  description = "Memory request of the Redis container for the default pub/sub broker."
  type        = string
  default     = "128Mi"
}

variable "redisMemoryLimit" {
  description = "Memory limit of the Redis container for the default pub/sub broker."
  type        = string
  default     = "1024Mi"
}
