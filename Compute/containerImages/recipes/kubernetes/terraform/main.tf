terraform {
  required_version = ">= 1.5"
}

# The recipe runs inside the dynamic-rp container. The chart mounts
# `buildctl` (copied from the BuildKit image by an init container)
# onto PATH and sets BUILDKIT_HOST=tcp://127.0.0.1:1234 to point at
# the in-Pod buildkitd sidecar. Registry credentials live in a
# Kubernetes Secret mounted at $HOME/.docker/config.json. We invoke
# buildctl directly because the kreuzwerker/docker provider talks the
# Docker Engine HTTP API, which buildkitd does not implement.

locals {
  resource_name = lower(var.context.resource.name)
  properties    = try(var.context.resource.properties, {})

  # Per-resource override of the recipe-wide registry parameter.
  registry = coalesce(try(local.properties.registry, null), var.registry)

  build_context  = local.properties.build.context
  dockerfile     = try(local.properties.build.dockerfile, "Dockerfile")
  platforms      = try(local.properties.build.platforms, [])
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

  platform_opt = length(local.platforms) > 0 ? "--opt platform=${join(",", local.platforms)}" : ""

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
resource "terraform_data" "build_push" {
  triggers_replace = {
    image_ref = local.image_ref
    src_hash  = local.local_context_hash
  }

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    command     = <<-EOT
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
