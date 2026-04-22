## Overview

The `Radius.Compute/containerImages` resource type builds a container image from source and pushes it to a remote container registry (e.g. ghcr.io). It is always part of a Radius Application.

Builds run inside the cluster on a rootless [BuildKit](https://github.com/moby/buildkit) sidecar that ships with the dynamic-rp Pod. There is no host Docker socket, no privileged Pod, and no per-node host preparation. The recipe uses the Terraform [`kreuzwerker/docker`](https://registry.terraform.io/providers/kreuzwerker/docker/latest) provider, which speaks BuildKit gRPC natively.

Developer documentation is embedded in the resource type definition YAML and is accessible via `rad resource-type show Radius.Compute/containerImages`.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ dynamic-rp Pod                                                   │
│                                                                  │
│  ┌──────────────────────┐         ┌────────────────────────┐    │
│  │ dynamic-rp container │ ──────► │ buildkitd sidecar      │    │
│  │ (runs Terraform      │  unix   │ (rootless, no privs)   │    │
│  │  recipe)             │ socket  │                        │    │
│  └──────────────────────┘         └───────────┬────────────┘    │
│                                                │                 │
└────────────────────────────────────────────────┼─────────────────┘
                                                 │ HTTPS push
                                                 ▼
                                    ┌────────────────────────┐
                                    │ user's container       │
                                    │ registry               │
                                    └────────────────────────┘
```

## Recipes

| Platform | IaC Language | Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Terraform | `recipes/kubernetes/terraform/main.tf` | Alpha |

## Recipe Parameters

The platform engineer registers the recipe once per environment with a default registry path. Registry credentials are delivered separately as a Kubernetes Secret mounted into dynamic-rp by the Helm chart (see [Prerequisites](#prerequisites)); they are not recipe parameters.

```bash
rad recipe register default \
  --resource-type Radius.Compute/containerImages \
  --template-kind terraform \
  --template-path "git::https://github.com/radius-project/resource-types-contrib.git//Compute/containerImages/recipes/kubernetes/terraform" \
  --parameters registry=ghcr.io/myorg
```

| Parameter | Required | Description |
|---|---|---|
| `registry` | yes | Registry path images are pushed under, e.g. `ghcr.io/myorg`. The recipe composes `<registry>/<resource-name>:<tag>` to form the full image reference. May be overridden per-resource via `properties.registry`. |

## Resource Properties

| Property | Required | Description |
|---|---|---|
| `environment` | yes | Radius Environment ID. |
| `application` | yes | Radius Application ID. |
| `tag` | no | Tag for the produced image. Defaults to a content-addressable digest (`sha256-<hash>`) computed from the build inputs. **Required** when `build.context` is a remote git URL. |
| `registry` | no | Per-resource override of the recipe's `registry` parameter. |
| `build.context` | yes | Source location. Either a git URL of the form `git::https://…` (BuildKit clones inside the cluster) or, for local-development workflows, a path that the rad CLI uploads as a tarball. |
| `build.dockerfile` | no | Path to the Dockerfile relative to the context. Defaults to `Dockerfile`. |
| `build.platforms` | no | Target platforms (e.g. `["linux/amd64", "linux/arm64"]`). When omitted, the build targets the BuildKit sidecar's native architecture. Multi-platform builds use cross-compilation. |

## Output Properties

| Output | Description |
|---|---|
| `properties.image` | The full resolved image reference, e.g. `ghcr.io/myorg/myimage:sha256-d4f2…`. Reference this from `Radius.Compute/containers` resources so they pick up new digests automatically. |

## Prerequisites

1. **dynamic-rp installed with the BuildKit sidecar enabled.** The default Helm install enables it. On Kubernetes < 1.30 (or any cluster without `UserNamespacesSupport`), install with `--set dynamicrp.buildkit.psaMode=baseline`.

2. **Registry credentials provisioned as a Kubernetes Secret.** The platform engineer creates a Secret in the dynamic-rp namespace whose `config.json` key holds a Docker config-format credentials document, then points the chart at it via `--set dynamicrp.buildkit.credentialsSecret=<secret-name>`.

   ```bash
   kubectl create secret generic ghcr-credentials \
     --from-file=config.json=$HOME/.docker/config.json \
     --namespace radius-system
   helm upgrade radius radius/radius \
     --set dynamicrp.buildkit.credentialsSecret=ghcr-credentials
   ```

## Multi-architecture builds

Multi-platform builds use cross-compilation. The Dockerfile must use the standard `BUILDPLATFORM` / `TARGETPLATFORM` build args:

```dockerfile
# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.22-alpine AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY . .
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /out/app .

FROM alpine
COPY --from=build /out/app /app
ENTRYPOINT ["/app"]
```

Dockerfiles whose `RUN` steps execute target-arch binaries (e.g. some `apt-get install` post-install scripts) will fail at build time with `exec format error`. The recipe does not silently fall back to a single arch, because that produces runtime crashes on foreign-arch nodes long after the deploy "succeeds." The remediation is to make the Dockerfile cross-compile-friendly or to drop the foreign architecture.

There is no QEMU/binfmt fallback in this design.

## Limitations

- **No `latest` for git contexts.** When `build.context` is a git URL, an explicit `properties.tag` is required. The recipe cannot compute a content-addressable tag from a remote tree, and defaulting to `latest` would defeat downstream reconciliation (the URL doesn't change between commits, so `properties.image` wouldn't change and Kubernetes wouldn't roll the Deployment).

- **Local context upload is deferred.** The first cut supports git URLs end-to-end. Local-path contexts will be uploaded by the rad CLI in a later iteration.
