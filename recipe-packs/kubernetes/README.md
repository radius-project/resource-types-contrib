# Kubernetes Recipe Pack

This folder contains the **Kubernetes Recipe Pack** — a collection of Recipes that provision Radius Resource Types on Kubernetes. Deploying the pack creates only a reusable `Radius.Core/recipePacks` resource. Create the target Radius Environment separately, then associate the pack with it.

| File | Description |
| --- | --- |
| `default.bicep` | Recipe Pack wiring the Bicep recipes for all Kubernetes-provisioned types. |

The pack declares one `Radius.Core/recipePacks` resource whose `recipes` map contains an entry for every Resource Type. It does not create or modify a `Radius.Core/environments` resource.

## Recipes in this pack

Kube-recipes tagged `:edge` are rebuilt on every push to `main`; `:latest` and the version tags track stable releases.

| Resource Type | Kind | Source |
| --- | --- | --- |
| `Radius.Compute/containers` | Bicep | `ghcr.io/radius-project/kube-recipes/containers:latest` |
| `Radius.Compute/persistentVolumes` | Bicep | `ghcr.io/radius-project/kube-recipes/persistentvolumes:latest` |
| `Radius.Compute/routes` | Bicep | `ghcr.io/radius-project/kube-recipes/routes:latest` |
| `Radius.Compute/containerImages` | Bicep | `ghcr.io/radius-project/kube-recipes/containerimages:latest` |
| `Radius.Security/secrets` | Bicep | `ghcr.io/radius-project/kube-recipes/secrets:latest` |
| `Radius.Data/mySqlDatabases` | Bicep | `ghcr.io/radius-project/kube-recipes/mysqldatabases:latest` |
| `Radius.Data/postgreSqlDatabases` | Bicep | `ghcr.io/radius-project/kube-recipes/postgresqldatabases:latest` |
| `Radius.Data/redisCaches` | Bicep | `ghcr.io/radius-project/kube-recipes/rediscaches:latest` |
| `Radius.Messaging/rabbitMQ` | Bicep | `ghcr.io/radius-project/kube-recipes/rabbitmq:latest` |

### Container images and the in-cluster registry

The `Radius.Compute/containerImages` Recipe builds images with the rootless BuildKit sidecar in the Radius control plane and pushes them to the registry set by `containerImagesRegistry`. With a Radius release that includes the matching Helm chart changes, BuildKit (`dynamicrp.buildkit.enabled`) and an in-cluster OCI registry, `radius-registry` (`dynamicrp.buildkit.registry.enabled`), are enabled by default. The registry is exposed on NodePort `31500` (`dynamicrp.buildkit.registry.nodePort`). BuildKit pushes to `localhost:31500/<name>:<tag>` and the node's container runtime pulls the same reference through the NodePort, so the pack's default `containerImagesRegistry` of `localhost:31500` works without extra configuration.

BuildKit requires the Pod Security Admission `privileged` level on the Radius namespace. Opt out with Helm values when installing Radius:

- `--set dynamicrp.buildkit.registry.enabled=false` disables the in-cluster registry. Deploy the pack with `containerImagesRegistry` set to an external registry (e.g. `ghcr.io/my-org`) and, if that registry requires authentication, `containerImagesRegistrySecretName` set to a Secret with `username` and `password` keys.
- `--set dynamicrp.buildkit.enabled=false` disables image builds entirely, so `Radius.Compute/containerImages` resources cannot be deployed. Without BuildKit the Radius installation is compatible with the PSA `baseline` level.

The in-cluster registry is intended for development and has these limitations:

- It is unauthenticated.
- Pulls from `localhost:31500` rely on kube-proxy in `iptables` mode routing loopback traffic to the NodePort. They may fail with `nftables` or `ipvs` kube-proxy modes, or with a kube-proxy replacement such as Cilium. Use an external registry on those clusters.
- Images are stored in an `emptyDir` volume and are lost when the registry Pod restarts, unless a PVC is provided with `dynamicrp.buildkit.registry.persistence.existingClaim`.
- It is only reachable from the cluster that runs Radius, so it cannot be used when deploying to a different target cluster.
- If `dynamicrp.buildkit.registry.nodePort` is changed, set `containerImagesRegistry` to `localhost:<nodePort>` to match.

## Parameters

Every parameter has a default, so the pack deploys without any parameters.

| Parameter | Description |
| --- | --- |
| `containerImagesRegistry` | Registry path that `Radius.Compute/containerImages` pushes built images to. Defaults to `localhost:31500`, the in-cluster registry. Set to an external registry (e.g. `ghcr.io/my-org`) when the in-cluster registry is disabled. |
| `containerImagesRegistrySecretName` | Name of the Kubernetes Secret holding registry credentials for `Radius.Compute/containerImages`. Optional; defaults to empty for an unauthenticated registry. |

## Deploying

Create the Environment first:

```bash
rad env create default \
  --kubernetes-namespace default \
  --preview
```

Deploy the Recipe Pack into that existing Environment, then associate it:

```bash
rad deploy recipe-packs/kubernetes/default.bicep \
  --environment default

rad env update default \
  --recipe-packs default \
  --preview
```

To push built images to an external registry instead of the in-cluster registry, override the `containerImages` parameters when deploying the pack:

```bash
rad deploy recipe-packs/kubernetes/default.bicep \
  --environment default \
  --parameters containerImagesRegistry=ghcr.io/my-org \
  --parameters containerImagesRegistrySecretName=ghcr-creds
```

After the association is updated, every Resource Type the pack covers can be used in an application deployed to that Environment.

## Contributing a Recipe

To add a Recipe for another Resource Type to this pack, add an entry to the `recipes` map keyed by the Resource Type (for example `Radius.Data/mySqlDatabases`). For guidance on writing Recipes and wiring them into a Recipe Pack, see [Contributing Resource Types and Radius Recipes](../../docs/contributing/contributing-resource-types-recipes.md#recipes-and-recipe-packs).
