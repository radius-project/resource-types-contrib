terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
    }
  }
}

# The recipe runs inside the dynamic-rp Pod, so the kubernetes provider
# uses in-cluster service-account credentials by default. Do not set
# config_path; an empty string forces it to load kubeconfig from "" and
# fails before the provider can fall back to in-cluster auth.
provider "kubernetes" {}

# The recipe runs inside the dynamic-rp container. The chart mounts
# `buildctl` onto PATH and sets BUILDKIT_HOST to the in-Pod buildkitd
# sidecar.
#
# Registry credentials are platform-owned: the PE provisions a
# Radius.Security/secrets resource and passes its name via the recipe
# pack as `registrySecretName`. This recipe loads that K8s Secret,
# builds a Docker config.json, and exports DOCKER_CONFIG for buildctl
# --push. Cluster image pull (kubelet -> registry) is out of scope.

locals {
  resource_name = lower(var.context.resource.name)
  properties    = try(var.context.resource.properties, {})
  app_namespace = var.context.runtime.kubernetes.namespace

  registry      = var.registry
  registry_host = split("/", var.registry)[0]

  image_name = local.resource_name

  build_source  = local.properties.build.source
  dockerfile    = try(local.properties.build.dockerfile, "Dockerfile")
  platforms     = try(local.properties.build.platforms, ["linux/amd64", "linux/arm64"])
  is_git_source = can(regex("^git::", local.build_source))

  go_getter_stripped = local.is_git_source ? replace(local.build_source, "git::", "") : ""
  url_no_query       = local.is_git_source ? split("?", local.go_getter_stripped)[0] : ""
  query_part         = local.is_git_source ? (length(split("?", local.go_getter_stripped)) > 1 ? split("?", local.go_getter_stripped)[1] : "") : ""
  ref_matches        = local.is_git_source ? regexall("(?:^|&)ref=([^&]+)", local.query_part) : []
  git_ref            = length(local.ref_matches) > 0 ? local.ref_matches[0][0] : ""

  url_sentinel = local.is_git_source ? replace(local.url_no_query, "://", ":|||") : ""
  url_segments = local.is_git_source ? split("//", local.url_sentinel) : []
  git_repo_url = local.is_git_source ? replace(local.url_segments[0], ":|||", "://") : ""
  git_subdir   = local.is_git_source && length(local.url_segments) > 1 ? local.url_segments[1] : ""

  # BuildKit git fragment forms: "#<ref>", "#<ref>:<subdir>", or
  # "#:<subdir>" (empty ref => default branch). Preserves the
  # go-getter subdirectory even when no ref= is supplied.
  git_fragment = local.is_git_source ? (
    local.git_subdir != "" ? "#${local.git_ref}:${local.git_subdir}" : (
      local.git_ref != "" ? "#${local.git_ref}" : ""
    )
  ) : ""

  buildctl_git_url = local.is_git_source ? "${local.git_repo_url}${local.git_fragment}" : ""

  user_tag = try(local.properties.tag, null)

  build_args = try(local.properties.build.args, {})

  # Hash inputs that uniquely identify the build, so the image tag is
  # content-addressable. For local sources, hash the file tree. For git
  # sources, hash the resolved URL (incl. ref and subdir), so a changed
  # ref produces a new tag. Both include the dockerfile path, platforms,
  # and build args.
  local_context_hash = local.is_git_source ? sha256(jsonencode({
    url        = local.buildctl_git_url
    dockerfile = local.dockerfile
    platforms  = local.platforms
    args       = local.build_args
    })) : sha256(join("", concat(
    [for f in fileset(local.build_source, "**") : "${f}:${filesha1("${local.build_source}/${f}")}"],
    [local.dockerfile],
    local.platforms,
    [jsonencode(local.build_args)],
  )))

  computed_tag = "sha256-${substr(local.local_context_hash, 0, 16)}"
  resolved_tag = coalesce(local.user_tag, local.computed_tag)

  image_ref = "${local.registry}/${local.image_name}:${local.resolved_tag}"

  platform_opt = "--opt platform=${join(",", local.platforms)}"

  build_arg_flags = join(" ", [for k, v in local.build_args : "--opt build-arg:${k}=${v}"])

  context_flags = local.is_git_source ? join(" ", compact([
    "--opt context=${local.buildctl_git_url}",
    "--opt filename=${local.dockerfile}",
    local.build_arg_flags,
    ])) : join(" ", compact([
    "--local context=${local.build_source}",
    "--local dockerfile=${local.build_source}",
    "--opt filename=${local.dockerfile}",
    local.build_arg_flags,
  ]))

  # When registrySecretName is set, load the same-named K8s Secret and
  # use it as DOCKER_CONFIG. Unset => unauthenticated registry.
  use_auth = var.registrySecretName != ""

  docker_config_dir  = "${path.module}/.docker-${local.resource_name}"
  docker_config_path = "${local.docker_config_dir}/config.json"
}

# Load PE-provisioned registry credentials from the recipe's runtime
# namespace. count=0 lets unauthenticated registries keep working.
data "kubernetes_secret" "registry_creds" {
  count = local.use_auth ? 1 : 0
  metadata {
    name      = var.registrySecretName
    namespace = local.app_namespace
  }
}

locals {
  # kubernetes_secret data source returns already-decoded values
  # (the provider decodes the base64 from the K8s API).
  #
  # try(..., "") guards against destroy-time evaluation: the Secret is
  # owned by a separate Radius.Security/secrets resource, so on teardown
  # it (or its namespace) may already be deleted while registrySecretName
  # is still set. In that case the data source read resolves to a null
  # .data map and indexing it crashes `terraform destroy`. The credentials
  # are never used on destroy, so degrading to "" is safe.
  registry_username = local.use_auth ? try(data.kubernetes_secret.registry_creds[0].data["username"], "") : ""
  registry_password = local.use_auth ? try(data.kubernetes_secret.registry_creds[0].data["password"], "") : ""

  docker_config_json = local.use_auth ? jsonencode({
    auths = {
      (local.registry_host) = {
        auth = base64encode("${local.registry_username}:${local.registry_password}")
      }
    }
  }) : ""
}

resource "terraform_data" "validate_inputs" {
  lifecycle {
    precondition {
      condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)*$", local.registry))
      error_message = "containerImages: registry must be <host>[:<port>][/<lowercase-path>] (no scheme, no '@', lowercase path components) (got ${local.registry})."
    }
    precondition {
      condition     = can(regex("^[a-z0-9][a-z0-9._-]*$", local.image_name))
      error_message = "containerImages: image name (lowercased) must match [a-z0-9][a-z0-9._-]* (got ${local.image_name})."
    }
    precondition {
      condition     = local.user_tag == null || can(regex("^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$", local.user_tag))
      error_message = "containerImages: properties.tag must match Docker tag spec [A-Za-z0-9_][A-Za-z0-9._-]{0,127} (got ${local.user_tag})."
    }
    precondition {
      condition     = !startswith(local.dockerfile, "/") && !strcontains(local.dockerfile, "..") && can(regex("^[A-Za-z0-9._/-]+$", local.dockerfile))
      error_message = "containerImages: properties.build.dockerfile must be a relative path (no leading '/' and no '..' segments) matching [A-Za-z0-9._/-]+ (got ${local.dockerfile})."
    }
    precondition {
      condition     = can(regex("^git::https://[A-Za-z0-9._:/@?=&%~+#-]+$", local.build_source)) || (!strcontains(local.build_source, "..") && can(regex("^[A-Za-z0-9._/+~-]+$", local.build_source)))
      error_message = "containerImages: properties.build.source must be a git::https URL or a filesystem path (no '..' segments) (got ${local.build_source})."
    }
    precondition {
      condition     = length(local.platforms) > 0
      error_message = "containerImages: properties.build.platforms must contain at least one platform when set."
    }
    precondition {
      condition = alltrue([
        for p in local.platforms : can(regex("^[a-z0-9]+/[a-z0-9]+(/[a-z0-9]+)?$", p))
      ])
      error_message = "containerImages: properties.build.platforms entries must match <os>/<arch>[/<variant>] (got ${jsonencode(local.platforms)})."
    }
    precondition {
      condition = alltrue([
        for k in keys(local.build_args) : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k))
      ])
      error_message = "containerImages: properties.build.args keys must match [A-Za-z_][A-Za-z0-9_]* (got ${jsonencode(keys(local.build_args))})."
    }
    precondition {
      condition = alltrue([
        for v in values(local.build_args) : !can(regex("[\\s\"'`$\\\\]", v))
      ])
      error_message = "containerImages: properties.build.args values must not contain whitespace or shell metacharacters (\", ', `, $, \\)."
    }
  }
}

# Render docker config.json under the module path; buildctl reads it
# via DOCKER_CONFIG. local_sensitive_file keeps the payload out of
# plan diffs.
resource "local_sensitive_file" "docker_config" {
  count           = local.use_auth ? 1 : 0
  filename        = local.docker_config_path
  content         = local.docker_config_json
  file_permission = "0600"
}

# Build & push via buildctl.
resource "terraform_data" "build_push" {
  triggers_replace = {
    image_ref     = local.image_ref
    src_hash      = local.local_context_hash
    config_sha256 = local.use_auth ? sha256(local.docker_config_json) : ""
  }

  depends_on = [
    terraform_data.validate_inputs,
    local_sensitive_file.docker_config,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    environment = {
      DOCKER_CONFIG = local.use_auth ? local.docker_config_dir : ""
    }
    command = <<-EOT
      set -eu
      buildctl build \
        --frontend dockerfile.v0 \
        ${local.context_flags} \
        ${local.platform_opt} \
        --output type=image,name=${local.image_ref},push=true
    EOT
  }
}

# Cluster image pull is a platform concern (cluster-wide pull secret,
# OCI mirror, kubelet credential providers); not handled here.

output "result" {
  value = {
    resources = []
    values = {
      imageReference = local.image_ref
    }
  }
  depends_on = [terraform_data.build_push]
}
