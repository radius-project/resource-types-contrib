variable "name" {
  description = "Name for the Redis deployment and service"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
}

variable "tags" {
  description = "Tags to apply to Kubernetes resources"
  type        = map(string)
}

variable "redis_image_tag" {
  description = "Redis image tag"
  type        = string
  default     = "7"
}

variable "redis_port" {
  description = "Redis port"
  type        = number
  default     = 6379
}
