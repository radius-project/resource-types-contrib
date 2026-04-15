## Overview

The Radius.Compute/containerImages Resource Type builds a container image from source and pushes it to a remote container registry (e.g., ghcr.io). It is always part of a Radius Application.

This resource type is designed for **local development workflows** where the source code is available on the Kubernetes node filesystem (e.g., via kind `extraMounts` or k3d `-v` flags). It uses [BuildKit](https://github.com/moby/buildkit) to build and push the image inside a Kubernetes Job.

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Compute/containerImages`.

## Architecture

```
Host machine                          Kubernetes node
┌─────────────────────┐              ┌──────────────────────────────┐
│ ~/dev/myapp/        │  extraMount  │ /app/myapp/                  │
│   Dockerfile        │ ──────────►  │   Dockerfile                 │
│   src/              │              │   src/                       │
└─────────────────────┘              │                              │
                                     │  Build Job pod:              │
                                     │  ┌────────────────────────┐  │
                                     │  │ BuildKit               │  │
                                     │  │  hostPath: /app/myapp  │  │
                                     │  │  → builds image        │  │
                                     │  │  → pushes to registry  │  │
                                     │  │  (creds from recipe    │  │
                                     │  │   parameters)          │  │
                                     │  └────────────────────────┘  │
                                     └──────────────────────────────┘
```

## Recipes

| Platform | IaC Language | Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Terraform | main.tf | Alpha |

## Recipe Parameters

Registry credentials are configured by the platform engineer when registering the recipe:

```bash
rad recipe register default \
  --resource-type Radius.Compute/containerImages \
  --template-kind terraform \
  --template-path "git::https://github.com/radius-project/resource-types-contrib.git//Compute/containerImages/recipes/kubernetes/terraform" \
  --parameters ghcr_username=YOUR_USERNAME \
  --parameters ghcr_token=YOUR_PAT
```

| Parameter | Default | Description |
|---|---|---|
| `ghcr_server` | `ghcr.io` | Registry server address |
| `ghcr_username` | `""` | Registry username |
| `ghcr_token` | `""` | Registry token or PAT (sensitive) |

## Recipe Input Properties

| Radius Property | Description |
|---|---|
| `image` | Full image reference including registry (e.g., `ghcr.io/myorg/myapp:latest`). Must be lowercase. |
| `build.context` | Host path to source directory (must be available on the Kubernetes node) |
| `build.dockerfile` | Dockerfile path relative to build context (default: `Dockerfile`) |
| `registry.server` | (Optional) Override registry server from recipe parameters |
| `registry.username` | (Optional) Override registry username from recipe parameters |
| `registry.token` | (Optional) Override registry token from recipe parameters |

## Recipe Output Properties

There are no output properties that need to be set by the Recipe.

## Limitations

- **Local development only**: Requires `hostPath` access to source code on the Kubernetes node. This works with kind (`extraMounts`), k3d (`-v` flags), Docker Desktop, and similar local Kubernetes distributions. It does not work with remote clusters unless the source is available on the node filesystem.

- **Privileged container**: BuildKit requires `securityContext.privileged: true`. Clusters with restrictive PodSecurityAdmission policies may block this. Consider using [BuildKit rootless mode](https://github.com/moby/buildkit/blob/master/docs/rootless.md) for environments that do not allow privileged containers.

- **Single-node clusters**: The Job is scheduled on any node. In multi-node clusters, the `hostPath` mount may not be available on the scheduled node. Use a single-node cluster or node affinity to ensure correct scheduling.

- **RBAC**: The `dynamic-rp` service account requires `batch/jobs` permissions. This must be configured by the platform engineer:

  ```bash
  kubectl patch clusterrole dynamic-rp --type=json -p='[
    {
      "op": "add",
      "path": "/rules/-",
      "value": {
        "apiGroups": ["batch"],
        "resources": ["jobs", "jobs/status"],
        "verbs": ["create", "delete", "get", "list", "patch", "update", "watch"]
      }
    }
  ]'
  ```
