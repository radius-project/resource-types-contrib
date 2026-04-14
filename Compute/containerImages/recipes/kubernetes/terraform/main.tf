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
  # Uses credentials from ~/.docker/config.json (set via `docker login`
  # on the dynamic-rp pod by the platform engineer).
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
