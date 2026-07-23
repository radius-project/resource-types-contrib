
variable "context" {
  description = "This variable contains Radius recipe context."
  type        = any
  default     = null
}

variable "memory" {
  description = "Memory request and Redis maxmemory budget for the Redis container, keyed by size (S, M, L)."
  type = map(object({
    memoryRequest = string
    maxmemory     = string
  }))
  default = {
    S = {
      memoryRequest = "256Mi"
      maxmemory     = "200mb"
    }
    M = {
      memoryRequest = "512Mi"
      maxmemory     = "400mb"
    }
    L = {
      memoryRequest = "1Gi"
      maxmemory     = "800mb"
    }
  }
}
