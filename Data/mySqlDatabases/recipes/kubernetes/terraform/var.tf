variable "context" {
  description = "Information about the Radius resource that calls this Recipe."
  type        = any

  validation {
    condition     = contains(["5.7", "8.0", "8.4"], coalesce(try(var.context.resource.properties.version, null), "8.4"))
    error_message = "MySQL version must be 5.7, 8.0, or 8.4."
  }

  validation {
    condition     = contains(["required", "optional"], coalesce(try(var.context.resource.properties.tls, null), "required"))
    error_message = "MySQL tls must be required or optional."
  }
}
