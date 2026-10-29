variable "context" {
  description = "This variable contains Radius recipe context."
  type        = any
  default     = null
}

variable "redisImageTag" {
  description = "Tag of the redis container image for the default configuration store."
  type        = string
  default     = "7-alpine"
}

variable "redisMemoryRequest" {
  description = "Memory request of the Redis container for the default configuration store."
  type        = string
  default     = "128Mi"
}

variable "redisMemoryLimit" {
  description = "Memory limit of the Redis container for the default configuration store."
  type        = string
  default     = "1024Mi"
}
