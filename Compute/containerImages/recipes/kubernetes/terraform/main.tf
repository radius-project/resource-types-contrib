terraform {
  required_version = ">= 1.5"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = ">= 3.0"
    }
  }
}

provider "docker" {
  # Uses the Docker socket mounted into the dynamic-rp pod.
  # Enabled via: rad install kubernetes --set dynamicrp.docker.enabled=true

  registry_auth {
    address  = local.registry_server
    username = local.registry_username
    password = local.registry_token
  }
}

# ── Locals ───────────────────────────────────────────────────────────

locals {
  resource_name   = var.context.resource.name
  namespace       = var.context.runtime.kubernetes.namespace
  normalized_name = local.resource_name

  properties    = try(var.context.resource.properties, {})
  image         = local.properties.image
  build_context = local.properties.build.context
  dockerfile    = try(local.properties.build.dockerfile, "Dockerfile")

  # Registry credentials from resource properties or recipe parameters
  registry_server   = try(local.properties.registry.server, var.ghcr_server)
  registry_username = try(local.properties.registry.username, var.ghcr_username)
  registry_token    = try(local.properties.registry.token, var.ghcr_token)
}

# ── Build and push ───────────────────────────────────────────────────
# Uses the Docker daemon (via mounted socket) to build and push.
# No Kubernetes Job, no privileged containers, no RBAC patches needed.

resource "docker_image" "build" {
  name = local.image

  build {
    context    = local.build_context
    dockerfile = local.dockerfile
  }

  triggers = {
    # Rebuild when source directory contents change
    dir_sha1 = sha1(join("", [
      for f in fileset(local.build_context, "**") :
      filesha1("${local.build_context}/${f}")
    ]))
  }
}

resource "docker_registry_image" "push" {
  name          = docker_image.build.name
  keep_remotely = true
}

# ── Outputs ──────────────────────────────────────────────────────────

output "result" {
  value = {
    resources = []
  }
}
