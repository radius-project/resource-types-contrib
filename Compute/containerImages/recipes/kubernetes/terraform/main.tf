terraform {
  required_version = ">= 1.5"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = ">= 3.0"
    }
  }
}

# The provider talks to BuildKit over the unix socket exposed by the
# in-Pod buildkitd sidecar. The endpoint is supplied via the
# DOCKER_HOST environment variable set on the dynamic-rp container by
# the Helm chart, so we deliberately do not configure `host` here.
#
# Registry credentials live in a Kubernetes Secret mounted into the
# dynamic-rp container at $HOME/.docker/config.json by the Helm chart.
# The provider expands `~` against HOME on the recipe-runner process.
provider "docker" {
  registry_auth {
    address     = local.registry_host
    config_file = pathexpand("~/.docker/config.json")
  }
}

locals {
  resource_name = lower(var.context.resource.name)
  properties    = try(var.context.resource.properties, {})

  # Per-resource override of the recipe-wide registry parameter.
  registry      = coalesce(try(local.properties.registry, null), var.registry)
  registry_host = regex("^[^/]+", local.registry)

  build_context  = local.properties.build.context
  dockerfile     = try(local.properties.build.dockerfile, "Dockerfile")
  platforms      = try(local.properties.build.platforms, [])
  is_git_context = can(regex("^git::", local.build_context))

  # Content-addressable tag (default).
  #
  # For a local-path context we hash the directory contents, the
  # Dockerfile path, and the requested platforms. This makes
  # `properties.image` change on every code change and lets downstream
  # `containers` resources observe a real property change.
  #
  # For a git context the recipe cannot read the remote tree from the
  # control plane, so we cannot compute a content hash. We require an
  # explicit `properties.tag` in that case and fail otherwise.
  user_tag = try(local.properties.tag, null)

  local_context_hash = local.is_git_context ? "" : sha256(join("", concat(
    [for f in fileset(local.build_context, "**") : filesha1("${local.build_context}/${f}")],
    [local.dockerfile],
    local.platforms,
  )))

  computed_tag = local.is_git_context ? null : "sha256-${substr(local.local_context_hash, 0, 16)}"
  resolved_tag = coalesce(local.user_tag, local.computed_tag, "")

  image_ref = "${local.registry}/${local.resource_name}:${local.resolved_tag}"
}

# Fail loudly if a git context is used without an explicit tag. The
# alternative (defaulting to `latest` or hashing the URL) defeats
# downstream reconciliation: the URL doesn't change between commits,
# so `properties.image` wouldn't change and Kubernetes wouldn't roll
# the Deployment.
resource "terraform_data" "validate_git_tag" {
  input = local.is_git_context
  lifecycle {
    precondition {
      condition     = !local.is_git_context || local.user_tag != null
      error_message = "containerImages: when build.context is a git URL, properties.tag must be set explicitly. The recipe cannot compute a content-addressable tag from a remote tree."
    }
  }
}

# Build. For git contexts use `remote_context` (the kreuzwerker/docker
# provider treats `context` as a path-only field; remote URLs go in
# `remote_context`). For local contexts use `context`.
resource "docker_image" "build" {
  name = local.image_ref

  build {
    context        = local.is_git_context ? "." : local.build_context
    remote_context = local.is_git_context ? local.build_context : null
    dockerfile     = local.dockerfile
    platform       = length(local.platforms) > 0 ? join(",", local.platforms) : null
  }

  triggers = {
    image_ref = local.image_ref
    src_hash  = local.local_context_hash
  }
}

resource "docker_registry_image" "push" {
  name          = docker_image.build.name
  keep_remotely = true
}

output "result" {
  value = {
    resources = []
    values = {
      image = local.image_ref
    }
  }
}
