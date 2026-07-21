## Overview

The Radius.Compute/containerImages Resource Type builds a container image from source and pushes it to a container registry.

Builds run on the Radius control plane inside the dynamic-rp Pod using a rootless BuildKit sidecar. There is no host Docker socket, no privileged container, and no per-node host preparation. The Bicep Recipe carries a `build.sh` script (embedded into the published Recipe artifact at `rad bicep publish` time); the Radius Bicep driver executes that script inside the dynamic-rp container, where the `buildctl` CLI is mounted on PATH and the in-Pod buildkitd sidecar is reachable via `BUILDKIT_HOST`. The Recipe returns `imageReference` only after the image push succeeds, so resources consuming the image never observe a reference that does not yet exist.

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Compute/containerImages`.

## Prerequisites

Using the containerImages resource requires platform engineers to configure the containerImages Recipe with the target OCI registry. Developers cannot use containerImages without these steps complete.

1. Radius must be installed with the BuildKit sidecar enabled: `rad install kubernetes --set dynamicrp.buildkit.enabled=true` (or the equivalent Helm value). The `radius-system` namespace must permit the sidecar's rootless BuildKit security profile; Kubernetes PSA `baseline` and `restricted` enforcement reject the required profile, so use an unlabeled namespace or `privileged` enforcement after evaluating the cluster's security policy.

2. The Radius Environment or Recipe Pack must define a Recipe parameter `registry` with the target registry prefix images are pushed under. This is a registry hostname optionally followed by a path (e.g. `ghcr.io` or `ghcr.io/my-org`); the recipe appends `/<resource-name>:<tag>` to form the full image reference.

3. If the registry requires authentication, a Secret containing `username` and `password` must exist in each consuming resource's runtime namespace, then the `registrySecretName` Recipe parameter must be set on the Environment or Recipe Pack. An application-scoped `Radius.Security/secrets` resource can materialize this Secret.

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
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containerimages:latest'
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

A list of available Recipes for this Resource Type, including links to the Recipe templates:

| Platform | IaC Language | Recipe Name | Stage |
| --- | --- | --- | --- |
| Kubernetes | Bicep | recipes/kubernetes/bicep/kubernetes-containerimages.bicep | Alpha |
| Kubernetes | Terraform | recipes/kubernetes/terraform/main.tf | Alpha |

The Bicep recipe requires a Radius control plane that supports the private `imageBuild` hook. Upgrade the control plane before switching an existing Recipe Pack from Terraform to Bicep.

## Recipe Input Properties

Properties for the containerImages resource are provided to the Recipe via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.resource.properties.build.source` (string, required): The build context. This can be a `git::https://...` URL, which BuildKit clones inside the cluster, or a local filesystem directory that is already visible inside the dynamic-rp container. Use an absolute path for a local directory; Radius does not upload a directory from the user's workstation, and relative paths resolve from a transient recipe working directory.
- `context.resource.properties.build.dockerfile` (string, optional): Path to the Dockerfile relative to the build context. Defaults to `Dockerfile`.
- `context.resource.properties.build.platforms` (array of string, optional): Target platforms (e.g. `["linux/amd64", "linux/arm64"]`) for the multi-arch image. Defaults to `["linux/amd64", "linux/arm64"]`. Multi-arch builds require a cross-compile-friendly Dockerfile.
- `context.resource.properties.build.args` (object, optional): Map of `--build-arg` values passed to the build.
- `context.resource.properties.tag` (string, optional): Explicit image tag. When omitted, defaults to a deterministic tag (`sha256-<hash>`) derived from the build inputs (source URL or file tree, dockerfile path, platforms, build args). A present tag must be a valid non-empty string and is used as-is, skipping this hash calculation.

The Recipe is also parameterized at registration time by the platform engineer with:

- `registry` (string, required): The registry prefix images are pushed under (e.g. `ghcr.io/myorg`). The recipe composes `<registry>/<resource-name>:<tag>` to form the full image reference.
- `registrySecretName` (string, optional): Name of a Kubernetes Secret in the recipe runtime namespace on the target Kubernetes cluster (typically materialized by an application-scoped `Radius.Security/secrets` resource of `kind: generic` with `username` and `password` keys). Omit for unauthenticated registries.

## Recipe Output Properties

The Kubernetes recipe emits the following output values:

- `imageReference` (string): The full resolved image reference, e.g. `ghcr.io/myorg/myimage:v1.2.3`. Reference this from `Radius.Compute/containers` resources via a Radius connection. The value is reported by the build script after the push succeeds.

## Customizing the build script

The imperative part of the Bicep Recipe lives in `recipes/kubernetes/bicep/build.sh`, next to the Recipe's `.bicep` file. It validates the build inputs, translates the go-getter source URL into a BuildKit context, computes a deterministic default tag from the build inputs, runs `buildctl build ... --output type=image,push=true`, and reports `imageReference` back to Radius through the `RADIUS_EXEC_OUTPUT` result file.

To customize the build (different buildctl options, extra steps, a different tag scheme):

1. Fork this recipe directory and edit `build.sh` (and `kubernetes-containerimages.bicep` if the script needs different inputs).
2. Publish the fork: `rad bicep publish --file kubernetes-containerimages.bicep --target br:<your-registry>/<path>:<tag>`. The script is embedded into the published artifact by `loadTextContent`.
3. Point your Recipe Pack's `Radius.Compute/containerImages` entry at the published artifact.

Radius executes only script content embedded in the registered Recipe artifact. Build inputs (tags, build args, sources) are passed as positional data, never interpolated into shell code. The script runs in the dynamic-rp container (Alpine: BusyBox `sh`, `sha256sum`, `git`, plus `buildctl`).

Note on tags and rebuilds: the Bicep recipe rebuilds and re-pushes synchronously on every recipe execution. Unchanged build inputs produce the same deterministic image reference, but an explicit tag or a moving Git ref can replace the image content behind an existing tag; pin Git sources to an immutable commit when stable content is required. The Terraform recipe retains its `triggers_replace` behavior and does not rebuild when its tracked inputs are unchanged.

The Bicep and Terraform recipes hash the same categories of build inputs but serialize them differently, so their generated `sha256-*` tags are stable within each implementation but are not guaranteed to be byte-for-byte equal. Switching recipe kinds without setting an explicit tag can therefore cause a one-time image reference change. Exact cross-implementation hash equality is not part of the resource contract.
