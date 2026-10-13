## Overview

The Radius.Compute/containerImages Resource Type builds a container image from source and pushes it to a container registry.

Builds run on the Radius control plane inside the dynamic-rp Pod using a rootless BuildKit sidecar. There is no host Docker socket, no privileged Pod, and no per-node host preparation. The Recipe uses BuildKit by invoking the `buildctl` CLI mounted into the dynamic-rp container; the in-cluster buildkitd sidecar exposes its gRPC API on Pod loopback TCP.

The Bicep Recipe embeds a platform-engineer-authored `build.sh` script. A scoped Radius Bicep driver hook runs the script and returns `imageReference` only after the image push succeeds.

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Compute/containerImages`.

## Prerequisites

With a Radius release that includes the matching Helm chart changes, the containerImages resource works out of the box on the default Kubernetes Recipe Pack:

- The BuildKit sidecar (`dynamicrp.buildkit.enabled`) and an in-cluster OCI registry, `radius-registry` (`dynamicrp.buildkit.registry.enabled`), are enabled by default. The registry is exposed on NodePort `31500`; BuildKit pushes to `localhost:31500/<name>:<tag>` and the node's container runtime pulls the same reference through the NodePort.
- The default Kubernetes Recipe Pack ([`recipe-packs/kubernetes/default.bicep`](../../recipe-packs/kubernetes/default.bicep)) wires this Recipe with `registry: 'localhost:31500'`.

The in-cluster registry is intended for development. It is unauthenticated, stores images in an `emptyDir` volume unless `dynamicrp.buildkit.registry.persistence.existingClaim` is set, relies on kube-proxy in `iptables` mode for `localhost` NodePort pulls (it may fail with `nftables`, `ipvs`, or kube-proxy replacements such as Cilium), and cannot be used when deploying to a different target cluster. If `dynamicrp.buildkit.registry.nodePort` is changed, update the Recipe's `registry` parameter to match. See the [Kubernetes Recipe Pack README](../../recipe-packs/kubernetes/README.md#container-images-and-the-in-cluster-registry) for details.

BuildKit requires the Pod Security Admission `privileged` level on the Radius namespace. If using Kubernetes < 1.30, Radius must be installed with `--set dynamicrp.buildkit.psaMode=baseline`.

To use an external registry instead:

1. Optionally disable the in-cluster registry during installation with `--set dynamicrp.buildkit.registry.enabled=false`. To disable image builds entirely, set `--set dynamicrp.buildkit.enabled=false`; containerImages resources then cannot be deployed.

2. Set the Recipe parameter `registry` on the Environment or Recipe Pack to the target registry prefix images are pushed under. This is a registry hostname optionally followed by a path (e.g. `ghcr.io` or `ghcr.io/my-org`); the recipe appends `/<resource-name>:<tag>` to form the full image reference. With the default Kubernetes Recipe Pack, set the `containerImagesRegistry` pack parameter.

3. If the registry requires authentication, create a Radius secret resource, then set the `registrySecretName` Recipe parameter on the Environment or Recipe Pack (the `containerImagesRegistrySecretName` pack parameter for the default Kubernetes Recipe Pack).

For example, to use an external registry with a custom Recipe Pack:

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
        kind: 'terraform'
        source: 'git::https://github.com/radius-project/resource-types-contrib.git//Compute/containerImages/recipes/kubernetes/terraform'
        parameters: {
          registry: 'ghcr.io/my-org'
          registrySecretName: 'ghcr-creds'
        }
      }
    }
  }
}

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'my-app'
  properties: {
    environment: env.id
  }
}

resource ghcrCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'ghcr-creds'
  properties: {
    environment: env.id
    application: app.id
    data: {
      username: { value: registryUsername }
      password: { value: registryPassword }
    }
  }
}
```

## Recipes

A list of available Recipes for this Resource Type, including links to the Bicep and Terraform templates:

| Platform | IaC Language | Recipe Name | Stage |
| --- | --- | --- | --- |
| Kubernetes | Bicep | recipes/kubernetes/bicep/kubernetes-containerimages.bicep | Alpha |
| Kubernetes | Terraform | recipes/kubernetes/terraform/main.tf | Alpha |

The Bicep Recipe requires a Radius control plane that supports the private `imageBuild` hook. The default Kubernetes and Azure AKS Recipe Packs use the Bicep Recipe.

## Recipe Input Properties

Properties for the containerImages resource are provided to the Recipe via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.resource.properties.build.source` (string, required): The build context. Either a `git::https://...` URL or a local filesystem path. The default Bicep and Terraform Recipes accept local sources only beneath the operator-managed `/var/radius/build-contexts` root and reject symbolic links. For local sources, configure the Radius Helm chart with `dynamicrp.buildkit.localContexts.existingClaim` to mount an existing PVC read-only at that path; the chart does not create or populate the claim. Radius does not upload workstation source.
- `context.resource.properties.build.dockerfile` (string, optional): Path to the Dockerfile relative to the build context. Defaults to `Dockerfile`.
- `context.resource.properties.build.platforms` (array of string, optional): Target platforms (e.g. `["linux/amd64", "linux/arm64"]`) for the multi-arch image. Defaults to `["linux/amd64", "linux/arm64"]`. Multi-arch builds require a cross-compile-friendly Dockerfile.
- `context.resource.properties.build.args` (object, optional): Map of `--build-arg` values passed to the build.
- `context.resource.properties.tag` (string, optional): Explicit image tag. When omitted, the Recipe derives a deterministic tag (`sha256-<hash>`) from the build inputs. Pin Git sources to an immutable ref when stable content is required.

The Recipe is also parameterized at registration time by the platform engineer with:

- `registry` (string, required): The registry prefix images are pushed under (e.g. `ghcr.io/myorg`). The recipe composes `<registry>/<resource-name>:<tag>` to form the full image reference.
- `registrySecretName` (string, optional): Name of a Kubernetes Secret in the Recipe runtime namespace with `username` and `password` keys. Omit for unauthenticated registries.

## Recipe Output Properties

The Kubernetes recipe emits the following output values:

- `imageReference` (string): The full resolved image reference, e.g. `ghcr.io/myorg/myimage:v1.2.3`. Reference this from `Radius.Compute/containers` resources via a Radius connection.

## Customizing the Bicep build

Platform engineers can fork the Bicep Recipe, edit `build.sh`, and republish the module. Radius converts supported `imageBuild` values into command-line flags and injects the operator-owned registry; values are never interpolated into the script text.

The driver does not hard-code the `imageBuild` field names. Add, remove, or rename fields in `kubernetes-containerimages.bicep` and `build.sh` together without changing Radius. The Bicep Recipe rebuilds on every execution, unlike Terraform's state-based build suppression.
