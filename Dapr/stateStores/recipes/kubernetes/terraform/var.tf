variable "context" {
  description = "This variable contains Radius recipe context."
  type        = any
  default     = null
}

variable "actorStateStore" {
  description = "Sets the default Redis state store as the Dapr actor state store. Only one state store in a namespace can be the actor state store. Applies only when the resource does not set componentType."
  type        = bool
  default     = false
}

variable "redisImageTag" {
  description = "Tag of the redis container image for the default state store."
  type        = string
  default     = "7-alpine"
}

variable "redisMemoryRequest" {
  description = "Memory request of the Redis container for the default state store."
  type        = string
  default     = "128Mi"
}

variable "redisMemoryLimit" {
  description = "Memory limit of the Redis container for the default state store."
  type        = string
  default     = "1024Mi"
}
