# Kubernetes Recipe Pack

This folder contains the **Kubernetes Recipe Pack** — a collection of Recipes that provision Radius Resource Types on Kubernetes. Deploying the pack creates only a reusable `Radius.Core/recipePacks` resource. Create the target Radius Environment separately, then associate the pack with it.

| File | Description |
| --- | --- |
| `default.bicep` | Recipe Pack wiring the Bicep recipes for all Kubernetes-provisioned types. |

The pack declares one `Radius.Core/recipePacks` resource whose `recipes` map contains an entry for every Resource Type. It does not create or modify a `Radius.Core/environments` resource.

## Recipes in this pack

Kube-recipes tagged `:edge` are rebuilt on every push to `main`. `:latest` and the version tags track stable releases, but `:latest` moves to a new digest each time a release publishes, so pin a version tag if you need a reproducible deployment.

| Resource Type | Kind | Source |
| --- | --- | --- |
| `Radius.Compute/containers` | Bicep | `ghcr.io/radius-project/kube-recipes/containers:latest` |
| `Radius.Compute/persistentVolumes` | Bicep | `ghcr.io/radius-project/kube-recipes/persistentvolumes:latest` |
| `Radius.Compute/routes` | Bicep | `ghcr.io/radius-project/kube-recipes/routes:latest` |
| `Radius.Security/secrets` | Bicep | `ghcr.io/radius-project/kube-recipes/secrets:latest` |
| `Radius.Data/mySqlDatabases` | Bicep | `ghcr.io/radius-project/kube-recipes/mysqldatabases:latest` |
| `Radius.Data/postgreSqlDatabases` | Bicep | `ghcr.io/radius-project/kube-recipes/postgresqldatabases:latest` |
| `Radius.Data/redisCaches` | Bicep | `ghcr.io/radius-project/kube-recipes/rediscaches:latest` |
| `Radius.Messaging/rabbitMQ` | Bicep | `ghcr.io/radius-project/kube-recipes/rabbitmq:latest` |

This pack has seven Recipes and does not cover `Radius.Data/postgreSqlDatabases`. `rad env create` without `--recipe-packs` links Radius's own built-in default pack, which has eight Recipes, including PostgreSQL, pinned to the SHA tags of that Radius release. **Deploying this pack into the same pack ID overwrites that built-in pack.** Only deploy this pack when you want this exact set of Recipes, or when you know the Environment does not already use the built-in default pack.

## Prerequisite: `bicepconfig.json`

`rad deploy` needs a `bicepconfig.json` that registers the `radius` extension. This repo does not commit one. Before deploying, create one above `recipe-packs/` (Bicep looks for `bicepconfig.json` by walking up from the `.bicep` file's directory, not your current directory), for example the file `rad init --preview` scaffolds:

```json
{
  "extensions": {
    "radius": "br:biceptypes.azurecr.io/radius:<rad-version>"
  }
}
```

## Deploying

Create the Environment first:

```bash
rad env create default \
  --kubernetes-namespace default \
  --preview
```

`rad deploy` writes the pack to your workspace's **current** resource group, not the Environment's group, and Radius's built-in default pack always lives in group `default`. Pass `--group default` so the pack lands in the same group as the Environment. If your workspace's current group is not `default`, also pass the Environment's full ID instead of its name:

```bash
rad deploy recipe-packs/kubernetes/default.bicep \
  --group default \
  --environment default
```

```bash
# From a workspace scoped to a group other than "default":
rad deploy recipe-packs/kubernetes/default.bicep \
  --group default \
  --environment /planes/radius/local/resourceGroups/default/providers/Radius.Core/environments/default
```

If the pack keeps the same ID as the Environment's current pack, the Environment's existing reference already resolves and no further step is needed. Only run `rad env update` if the Environment is not yet associated with the pack, and scope it to the Environment's own group (which may differ from `default`):

```bash
rad env update default \
  --group <environment-group> \
  --recipe-packs default \
  --recipe-pack-group default \
  --preview
```

After the association is confirmed, every Resource Type the pack covers can be used in an application deployed to that Environment.

## Contributing a Recipe

To add a Recipe for another Resource Type to this pack, add an entry to the `recipes` map keyed by the Resource Type (for example `Radius.Data/mySqlDatabases`). For guidance on writing Recipes and wiring them into a Recipe Pack, see [Contributing Resource Types and Radius Recipes](../../docs/contributing/contributing-resource-types-recipes.md#recipes-and-recipe-packs).
