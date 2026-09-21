# Kubernetes Recipe Pack

This folder contains the **Kubernetes Recipe Pack** — a collection of Recipes that provision Radius Resource Types on Kubernetes. Deploying the pack creates only a reusable `Radius.Core/recipePacks` resource. Create the target Radius Environment separately, then associate the pack with it.

| File | Description |
| --- | --- |
| `default-recipepack.bicep` | Recipe Pack wiring the Bicep recipes for all Kubernetes-provisioned types. |

The pack declares one `Radius.Core/recipePacks` resource whose `recipes` map contains an entry for every Resource Type. It does not create or modify a `Radius.Core/environments` resource.

## Recipes in this pack

Kube-recipes tagged `:edge` are rebuilt on every push to `main`; `:latest` and the version tags track stable releases.

| Resource Type | Kind | Source |
| --- | --- | --- |
| `Radius.Compute/containers` | Bicep | `ghcr.io/radius-project/kube-recipes/containers:latest` |
| `Radius.Compute/persistentVolumes` | Bicep | `ghcr.io/radius-project/kube-recipes/persistentvolumes:latest` |
| `Radius.Compute/routes` | Bicep | `ghcr.io/radius-project/kube-recipes/routes:latest` |
| `Radius.Security/secrets` | Bicep | `ghcr.io/radius-project/kube-recipes/secrets:latest` |
| `Radius.Data/mySqlDatabases` | Bicep | `ghcr.io/radius-project/kube-recipes/mysqldatabases:latest` |
| `Radius.Data/redisCaches` | Bicep | `ghcr.io/radius-project/kube-recipes/rediscaches:latest` |
| `Radius.Messaging/rabbitMQ` | Bicep | `ghcr.io/radius-project/kube-recipes/rabbitmq:latest` |

## Deploying

Create the Environment first:

```bash
rad env create default \
  --kubernetes-namespace default \
  --preview
```

Deploy the Recipe Pack into that existing Environment, then associate it:

```bash
rad deploy recipe-packs/kubernetes/default-recipepack.bicep \
  --environment default

rad env update default \
  --recipe-packs default \
  --preview
```

After the association is updated, every Resource Type the pack covers can be used in an application deployed to that Environment.

## Contributing a Recipe

To add a Recipe for another Resource Type to this pack, add an entry to the `recipes` map keyed by the Resource Type (for example `Radius.Data/mySqlDatabases`). For guidance on writing Recipes and wiring them into a Recipe Pack, see [Contributing Resource Types and Radius Recipes](../../docs/contributing/contributing-resource-types-recipes.md#recipes-and-recipe-packs).
