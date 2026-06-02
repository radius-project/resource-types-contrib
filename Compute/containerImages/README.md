## Overview
The Radius.Compute/containerImages Resource Type builds a container image from source and pushes it to a container registry.

Builds run on the Radius control plane inside the dynamic-rp Pod using a rootless BuildKit sidecar. There is no host Docker socket, no privileged Pod, and no per-node host preparation. The Recipe uses BuildKit by invoking the `buildctl` CLI mounted into the dynamic-rp container; the in-cluster buildkitd sidecar exposes its gRPC API on Pod loopback TCP.

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Compute/containerImages`.

## Prerequisites

Using the containerImages resource requires platform engineers to configure the containerImages Recipe with the target OCI registry. Developers cannot use containerImages without these steps complete.

1. The Radius Environment or Recipe Pack must define a Recipe parameter `registry` with the target OCI registry hostname.

2. If the registry requires authentication, a Radius secret resource must be created, then the `registrySecretName` Recipe parameter set on the Environment or Recipe Pack.

3. If using Kubernetes < 1.30, Radius must be installed with `--set dynamicrp.buildkit.psaMode=baseline`.

For example:

```bicep
extension radius

param registryUsername string
@secure()
param registryPassword string

resource env 'Radius.Core/environments@2025-08-01-preview' = {
  name: 'default'
  properties: {
    recipePacks: [ recipes.id ]
  }
}

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'container-images-recipe'
  properties: {
    recipes: {
      'Radius.Compute/containerImages': {
        recipeKind: 'terraform'
        recipeLocation: 'git::https://github.com/radius-project/resource-types-contrib.git//Compute/containerImages/recipes/kubernetes/terraform'
        parameters: {
          registry: 'ghcr.io/my-org'
          registrySecretName: 'ghcr-creds'
        }
      }
    }
  }
}

resource ghcrCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'ghcr-creds'
  properties: {
    environment: env.id
    kind: 'generic'
    data: {
      username: { value: registryUsername }
      password: { value: registryPassword }
    }
  }
}
```

## Recipes

A list of available Recipes for this Resource Type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Terraform | recipes/kubernetes/terraform/main.tf | Alpha |


## Recipe Input Properties

Properties for the containerImages resource are provided to the Recipe via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.resource.properties.build.source` (string, required): The build context. Either a `git::https://...` URL or a local filesystem path to a directory containing the build context.
- `context.resource.properties.build.dockerfile` (string, optional): Path to the Dockerfile relative to the build context. Defaults to `Dockerfile`.
- `context.resource.properties.build.platforms` (array of string, optional): Target platforms (e.g. `["linux/amd64", "linux/arm64"]`) for the multi-arch image. Defaults to `["linux/amd64", "linux/arm64"]`. Multi-arch builds require a cross-compile-friendly Dockerfile.
- `context.resource.properties.build.args` (object, optional): Map of `--build-arg` values passed to the build.
- `context.resource.properties.tag` (string, optional): Explicit image tag. Defaults to a content-addressable tag (`sha256-<hash>`) derived from the build inputs (source URL or file tree, dockerfile path, platforms, build args).

The Recipe is also parameterized at registration time by the platform engineer with:

- `registry` (string, required): The registry prefix images are pushed under (e.g. `ghcr.io/myorg`). The recipe composes `<registry>/<resource-name>:<tag>` to form the full image reference.
- `registrySecretName` (string, optional): Name of a Kubernetes Secret in the environment namespace (typically materialized by a `Radius.Security/secrets` resource of `kind: generic` with `username` and `password` keys). Omit for unauthenticated registries.


## Recipe Output Properties

The Kubernetes recipe emits the following output values:

- `imageReference` (string): The full resolved image reference, e.g. `ghcr.io/myorg/myimage:v1.2.3`. Reference this from `Radius.Compute/containers` resources via a Radius connection.
