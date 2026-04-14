terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
  }
}

provider "kubernetes" {
  config_path = ""
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

  # Registry credentials: use resource properties if provided, fall back to recipe parameters
  registry_server   = try(local.properties.registry.server, var.ghcr_server)
  registry_username = try(local.properties.registry.username, var.ghcr_username)
  registry_token    = try(local.properties.registry.token, var.ghcr_token)
  has_credentials   = local.registry_username != "" && local.registry_token != ""

  docker_config_json = jsonencode({
    auths = {
      (local.registry_server) = {
        username = local.registry_username
        password = local.registry_token
      }
    }
  })

  environment_segments = try(split("/", local.properties.environment), [])
  environment_label    = length(local.environment_segments) > 0 ? element(local.environment_segments, length(local.environment_segments) - 1) : ""

  # Hash of build inputs to ensure Job name changes when inputs change.
  # Kubernetes Jobs are immutable — this forces recreation on re-deploy.
  build_hash = substr(md5(jsonencode({
    image      = local.image
    context    = local.build_context
    dockerfile = local.dockerfile
    server     = local.registry_server
    username   = local.registry_username
    token      = local.registry_token
  })), 0, 8)

  labels = {
    "radapp.io/resource"    = local.resource_name
    "radapp.io/environment" = local.environment_label
    "radapp.io/application" = try(var.context.application.name, "")
  }
}

# ── Registry credentials secret ──────────────────────────────────────
# Created from recipe parameters configured by the platform engineer.

resource "kubernetes_secret_v1" "docker_config" {
  count = local.has_credentials ? 1 : 0

  metadata {
    name      = "${local.normalized_name}-registry"
    namespace = local.namespace
    labels    = local.labels
  }

  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = local.docker_config_json
  }
}

# ── Build Job ────────────────────────────────────────────────────────
# Mounts the source directory from the host via hostPath, then BuildKit
# builds and pushes the image to the remote registry.
#
# Limitations:
# - Requires hostPath access (kind extraMounts / k3d -v)
# - Requires privileged container (for BuildKit)

resource "kubernetes_job_v1" "build" {
  metadata {
    name      = "${local.normalized_name}-build-${local.build_hash}"
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    backoff_limit              = 3
    ttl_seconds_after_finished = 600

    template {
      metadata {
        labels = local.labels
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "build-and-push"
          image = "moby/buildkit:latest"

          command = [
            "buildctl-daemonless.sh",
            "build",
            "--frontend=dockerfile.v0",
            "--local=context=/workspace",
            "--local=dockerfile=/workspace",
            "--opt=filename=${local.dockerfile}",
            "--output=type=image,name=${local.image},push=true",
          ]

          volume_mount {
            name       = "source"
            mount_path = "/workspace"
            read_only  = true
          }

          dynamic "volume_mount" {
            for_each = local.has_credentials ? [1] : []
            content {
              name       = "docker-config"
              mount_path = "/root/.docker"
              read_only  = true
            }
          }

          security_context {
            privileged = true
          }
        }

        volume {
          name = "source"
          host_path {
            path = local.build_context
            type = "Directory"
          }
        }

        dynamic "volume" {
          for_each = local.has_credentials ? [1] : []
          content {
            name = "docker-config"
            secret {
              secret_name = kubernetes_secret_v1.docker_config[0].metadata[0].name
              items {
                key  = ".dockerconfigjson"
                path = "config.json"
              }
            }
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
  }

  depends_on = [kubernetes_secret_v1.docker_config]
}

# ── Outputs ──────────────────────────────────────────────────────────

output "result" {
  value = {
    resources = concat(
      ["/planes/kubernetes/local/namespaces/${local.namespace}/providers/batch/Job/${local.normalized_name}-build-${local.build_hash}"],
      local.has_credentials ? ["/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Secret/${local.normalized_name}-registry"] : []
    )
  }
}
