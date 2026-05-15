variable "context" {
  description = "Radius recipe context. Carries resource properties, environment, and runtime info."
  type        = any
  default     = null
}

variable "registry" {
  description = "Default registry path (e.g. `ghcr.io/myorg`) into which images are pushed."
  type        = string
}

variable "registrySecretName" {
  description = <<-EOT
    Name of a Kubernetes Secret of type `kubernetes.io/dockerconfigjson`,
    provisioned by the platform engineer, that holds the credentials the
    recipe uses to push to `registry`. The recipe also copies its
    `.dockerconfigjson` blob into the application namespace as a per-resource
    pull Secret so kubelet can pull the image with the same credentials.
    Developers never see this name.
  EOT
  type        = string
}

variable "registrySecretNamespace" {
  description = <<-EOT
    Namespace of `registrySecretName`. Defaults to `radius-system` so the
    PE only needs to create one Secret per environment alongside the
    Radius control plane.
  EOT
  type        = string
  default     = "radius-system"
}
