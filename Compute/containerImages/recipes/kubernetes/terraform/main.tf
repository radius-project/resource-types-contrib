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

provider "kubernetes" {
  config_path = ""
}

# The recipe runs inside the dynamic-rp container. The chart mounts
# `buildctl` (copied from the BuildKit image by an init container)
# onto PATH and sets BUILDKIT_HOST=tcp://127.0.0.1:1234 to point at
# the in-Pod buildkitd sidecar. We invoke buildctl directly because
# buildkitd does not implement the Docker Engine HTTP API that the
# kreuzwerker/docker provider depends on.
#
# Registry credentials reach the recipe via a `Radius.Security/secrets`
# resource referenced from the containerImages resource via
# `properties.secretName`. Radius realizes the secret as a Kubernetes
# Secret in the application's namespace; the recipe reads `USERNAME`
# and `PASSWORD` from it, composes a Docker config.json on disk, and
# points buildctl at it with DOCKER_CONFIG.

locals {
  resource_name = lower(var.context.resource.name)
  properties    = try(var.context.resource.properties, {})

  registry  = var.registry
  namespace = var.context.runtime.kubernetes.namespace

  build_context  = local.properties.build.context
  dockerfile     = try(local.properties.build.dockerfile, "Dockerfile")
  platforms      = try(local.properties.build.platforms, ["linux/amd64", "linux/arm64"])
  is_git_context = can(regex("^git::", local.build_context))

  # Translate go-getter style git URLs (used by Terraform module
  # sources and accepted by Radius) into buildkit's git frontend
  # syntax. Example transformation:
  #
  #   git::https://github.com/o/r.git//sub?ref=X
  #     →  url=https://github.com/o/r.git, ref=X, subdir=sub
  #
  # buildctl is then invoked with:
  #   --opt context=<url>#<ref>           (or just <url> when no ref)
  #   --opt context-sub-dir=<subdir>      (when subdir is present)
  go_getter_stripped = local.is_git_context ? replace(local.build_context, "git::", "") : ""

  # Pull the optional `?ref=…` query off; remember it for the buildctl
  # `#ref` suffix.
  url_no_query = local.is_git_context ? split("?", local.go_getter_stripped)[0] : ""
  query_part   = local.is_git_context ? (length(split("?", local.go_getter_stripped)) > 1 ? split("?", local.go_getter_stripped)[1] : "") : ""
  ref_matches  = local.is_git_context ? regexall("(?:^|&)ref=([^&]+)", local.query_part) : []
  git_ref      = length(local.ref_matches) > 0 ? local.ref_matches[0][0] : ""

  # Split the URL's repo part from the optional `//subdir` part.
  # The URL has exactly one `://` (scheme separator); any further
  # `//` is the go-getter subdir separator. Sentinel-replace the
  # scheme separator so split("//", …) reliably finds the subdir.
  url_sentinel = local.is_git_context ? replace(local.url_no_query, "://", ":|||") : ""
  url_segments = local.is_git_context ? split("//", local.url_sentinel) : []
  git_repo_url = local.is_git_context ? replace(local.url_segments[0], ":|||", "://") : ""
  git_subdir   = local.is_git_context && length(local.url_segments) > 1 ? local.url_segments[1] : ""

  # BuildKit's git frontend takes the subdir as part of the URL
  # fragment using the syntax "#<ref>:<subdir>" (see
  # gitutil.ParseGitRef in moby/buildkit). Build the fragment up
  # front: empty if no ref or subdir; "#<ref>" if only ref;
  # "#<ref>:<subdir>" if both. (A subdir without a ref isn't
  # representable in this syntax — a ref is always required when
  # using a subdir, which the validate_git_tag check below also
  # enforces.)
  git_fragment = local.is_git_context ? (
    local.git_ref == "" ? "" : (
      local.git_subdir == "" ? "#${local.git_ref}" : "#${local.git_ref}:${local.git_subdir}"
    )
  ) : ""

  buildctl_git_url = local.is_git_context ? "${local.git_repo_url}${local.git_fragment}" : ""

  # Content-addressable tag (default). For a local-path context we
  # hash the directory contents, the Dockerfile path, and the
  # requested platforms so `properties.image` changes on every code
  # change. For a git context the recipe cannot read the remote tree
  # from the control plane, so we require an explicit
  # `properties.tag`.
  user_tag = try(local.properties.tag, null)

  local_context_hash = local.is_git_context ? "" : sha256(join("", concat(
    [for f in fileset(local.build_context, "**") : filesha1("${local.build_context}/${f}")],
    [local.dockerfile],
    local.platforms,
  )))

  computed_tag = local.is_git_context ? null : "sha256-${substr(local.local_context_hash, 0, 16)}"
  resolved_tag = coalesce(local.user_tag, local.computed_tag, "")

  image_ref = "${local.registry}/${local.resource_name}:${local.resolved_tag}"

  # Platforms always has at least one entry (defaulted in the locals
  # above), so the flag is always emitted.
  platform_opt = "--opt platform=${join(",", local.platforms)}"

  # Compose the buildctl context flags up front so the heredoc stays
  # readable. For git contexts, BuildKit's git frontend takes both
  # ref and subdir from the URL itself ("#<ref>:<subdir>"); the
  # `--opt contextsubdir` flag is *not* honored by the git source
  # (only by local/named contexts), so we encode subdir in
  # buildctl_git_url. For local contexts we mount the directory
  # under the well-known `context` and `dockerfile` slots consumed
  # by the dockerfile.v0 frontend.
  context_flags = local.is_git_context ? join(" ", [
    "--opt context=${local.buildctl_git_url}",
    "--opt filename=${local.dockerfile}",
    ]) : join(" ", [
    "--local context=${local.build_context}",
    "--local dockerfile=${local.build_context}",
    "--opt filename=${local.dockerfile}",
  ])
}

# Resolve the registry-credentials secret. The developer (or platform
# engineer) declares a Radius.Security/secrets resource of
# `kind: dockerconfigjson` (with `username`, `password`, and `server`
# data keys) and references it from the containerImages resource via
# `properties.secretName`. Radius realizes that resource as a
# Kubernetes Secret of type `kubernetes.io/dockerconfigjson` in the
# application's namespace; the recipe reads the assembled
# `.dockerconfigjson` blob and writes it straight to disk for buildctl.
# The same Secret is referenced by Radius.Compute/containers via
# `imagePullSecrets` so kubelet can pull images without out-of-band
# credentials.
data "kubernetes_secret_v1" "registry_creds" {
  metadata {
    name      = local.properties.secretName
    namespace = local.namespace
  }
}

locals {
  # The kubernetes_secret_v1 data source returns `data` values already
  # decoded from the wire base64, so this is the raw Docker config.json
  # blob exactly as kubelet would consume it.
  docker_config_dir  = "${path.module}/.docker-config"
  docker_config_json = data.kubernetes_secret_v1.registry_creds.data[".dockerconfigjson"]
}

# Stage the Docker config.json on the recipe runner's filesystem.
# `DOCKER_CONFIG` (set in the local-exec env below) points buildctl at
# this directory.
resource "local_sensitive_file" "docker_config" {
  filename             = "${local.docker_config_dir}/config.json"
  content              = local.docker_config_json
  file_permission      = "0600"
  directory_permission = "0700"
}

# Reject inputs containing shell metacharacters before they ever reach
# the local-exec heredoc. Each interpolated value below appears
# unquoted in a `/bin/sh -c` command line; without these checks a
# resource like `tag: 'foo;rm -rf /'` would get RCE on the dynamic-rp
# Pod's user. The character class is intentionally permissive enough
# to cover the union of (a) container-registry refs (RFC 3986 host +
# path, plus `:` for the tag) and (b) Dockerfile-relative paths.
resource "terraform_data" "validate_inputs" {
  lifecycle {
    precondition {
      condition     = can(regex("^[A-Za-z0-9._:/@-]+$", local.registry))
      error_message = "containerImages: registry must match [A-Za-z0-9._:/@-]+ (got ${local.registry})."
    }
    precondition {
      condition     = can(regex("^[a-z0-9][a-z0-9._-]*$", local.resource_name))
      error_message = "containerImages: resource name (lowercased) must match [a-z0-9][a-z0-9._-]* (got ${local.resource_name})."
    }
    precondition {
      condition     = local.user_tag == null || can(regex("^[A-Za-z0-9._-]{1,128}$", local.user_tag))
      error_message = "containerImages: properties.tag must match [A-Za-z0-9._-]{1,128} (got ${local.user_tag})."
    }
    precondition {
      condition     = can(regex("^[A-Za-z0-9._/-]+$", local.dockerfile))
      error_message = "containerImages: properties.build.dockerfile must match [A-Za-z0-9._/-]+ (got ${local.dockerfile})."
    }
    precondition {
      # build.context is either a go-getter git URL (validated by the
      # split logic above; the regex here is defense-in-depth against
      # backticks/semicolons sneaking into a hand-crafted URL) or a
      # local filesystem path. Disallow anything else.
      condition     = can(regex("^(git::https?://[A-Za-z0-9._:/@?=&%~+#-]+|/[A-Za-z0-9._/+~-]+)$", local.build_context))
      error_message = "containerImages: properties.build.context must be a git::https URL or an absolute filesystem path (got ${local.build_context})."
    }
    precondition {
      condition = alltrue([
        for p in local.platforms : can(regex("^[a-z0-9]+/[a-z0-9]+(/[a-z0-9]+)?$", p))
      ])
      error_message = "containerImages: properties.build.platforms entries must match <os>/<arch>[/<variant>] (got ${jsonencode(local.platforms)})."
    }
  }
}

# Fail loudly if a git context is used without an explicit tag.
# Defaulting to `latest` or hashing the URL would defeat downstream
# reconciliation: the URL doesn't change between commits, so
# `properties.image` wouldn't change and Kubernetes wouldn't roll the
# Deployment.
resource "terraform_data" "validate_git_tag" {
  input = local.is_git_context
  lifecycle {
    precondition {
      condition     = !local.is_git_context || local.user_tag != null
      error_message = "containerImages: when build.context is a git URL, properties.tag must be set explicitly. The recipe cannot compute a content-addressable tag from a remote tree."
    }
  }
}

# Build & push via buildctl. Replacement is triggered by any change to
# the resolved image reference or the local context's content hash.
#
# Destroy semantics: `terraform destroy` removes this resource from
# state but does NOT delete the pushed image from the registry. This
# is intentional. Image deletion is a registry-side concern (some
# registries forbid tag deletion entirely; some require admin
# credentials beyond what the recipe is granted). Operators who need
# image cleanup should run a separate registry retention policy
# (e.g. ghcr.io's `actions/delete-package-versions`, ACR's
# `acr purge`, etc).
resource "terraform_data" "build_push" {
  triggers_replace = {
    image_ref = local.image_ref
    src_hash  = local.local_context_hash
  }

  # Block any build until input validation has succeeded, so a bad
  # input never reaches the local-exec command line. Also depend on
  # the staged Docker config so buildctl always has registry creds
  # at hand.
  depends_on = [
    terraform_data.validate_inputs,
    terraform_data.validate_git_tag,
    local_sensitive_file.docker_config,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    environment = {
      DOCKER_CONFIG = local.docker_config_dir
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

output "result" {
  value = {
    resources = []
    values = {
      image = local.image_ref
    }
  }
  # Ensure the build runs before the output is materialized.
  depends_on = [terraform_data.build_push]
}
