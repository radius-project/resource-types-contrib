## Overview
The Radius.Compute/containerImages Resource Type builds a container image from source and pushes it to a container registry.

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Compute/containerImages`.

## Recipes

A list of available Recipes for this Resource Type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Terraform | recipes/kubernetes/terraform/main.tf | Alpha |


## Recipe Input Properties

Properties for the containerImages resource are provided to the Recipe via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.resource.properties.build.source` (string, required): The build context. Either a `git::https://...` URL or a local filesystem path. In the case of a local path, the rad CLI will package upload the source for the container build.
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
