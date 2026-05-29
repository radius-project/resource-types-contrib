variable "context" {
  description = "This variable contains Radius recipe context."
  type        = any
  default     = null
}

variable "hostname" {
  description = "Hostname to use for the Contour HTTPProxy virtual host when the route does not specify hostnames."
  type        = string
  default     = "localhost"
}
