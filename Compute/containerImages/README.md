## Overview

The Radius.Compute/containerImages Resource Type builds a container image from source and pushes it to a container registry. It is always part of a Radius Application.

Builds run inside the cluster on a rootless BuildKit sidecar that ships with the dynamic-rp Pod. The recipe shells `buildctl` against the sidecar; no host Docker socket, no privileged containers, and no per-node host preparation.

Developer documentation is embedded in the Resource Type definition YAML file and is accessible via `rad resource-type show Radius.Compute/containerImages`.

## Recipes

| Platform | IaC Language | Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Terraform | `recipes/kubernetes/terraform/main.tf` | Alpha |

## Recipe Parameters

| Parameter | Required | Description |
|---|---|---|
| `registry` | yes | Registry path images are pushed under (e.g. `ghcr.io/myorg`). The recipe composes `<registry>/<resource-name>:<tag>` to form the full image reference. |
| `registrySecretName` | no | Name of a Kubernetes Secret in the environment namespace (typically materialized by a `Radius.Security/secrets` resource) with `username` and `password` keys. Omit for unauthenticated registries. |

## Output Properties

| Output | Description |
|---|---|
| `properties.imageReference` | The full resolved image reference, e.g. `ghcr.io/myorg/myimage:v1.2.3`. Reference this from `Radius.Compute/containers` resources. |

## Limitations

- **Explicit `tag` required for git sources.** The recipe cannot compute a content-addressable tag from a remote tree; defaulting to `latest` would defeat downstream reconciliation.
- **Local context upload deferred.** `build.source` accepts a `git::https` URL or an absolute filesystem path already available to the Terraform runtime. CLI-driven local-path upload is planned but not yet implemented.
- **No QEMU/binfmt fallback for multi-arch.** Dockerfiles must cross-compile via `BUILDPLATFORM`/`TARGETPLATFORM`; native execution of foreign-arch binaries during the build will fail.
