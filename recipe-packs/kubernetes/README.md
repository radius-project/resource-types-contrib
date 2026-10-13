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

`rad init --preview` and `rad env create --preview` (without `--recipe-packs`) link Radius's built-in default pack, `/planes/radius/local/resourceGroups/default/providers/Radius.Core/recipePacks/default`. Radius builds that pack from this file at the release it pins, replacing each `:latest` source with a tag pinned for that Radius release (`:edge` for edge builds). **Deploying this file to the same pack ID overwrites the built-in pack for every Environment that references it and switches all of its sources to `:latest`.** To get the built-in pack back, see [Restoring Radius's default pack](#restoring-radiuss-default-pack).

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

`rad deploy` writes the pack to your workspace's **current** resource group, and Radius's built-in default pack always lives in group `default`. Pass `--group default` so the pack lands in group `default`. With `--group default`, `--environment <name>` is also looked up in group `default`; if the Environment is in another group, pass its full ID instead:

```bash
rad deploy recipe-packs/kubernetes/default.bicep \
  --group default \
  --environment default
```

```bash
# When the Environment is in a group other than "default":
rad deploy recipe-packs/kubernetes/default.bicep \
  --group default \
  --environment /planes/radius/local/resourceGroups/<environment-group>/providers/Radius.Core/environments/<env-name>
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

## Restoring Radius's default pack

Deploying this file cannot restore the exact pack Radius creates, because its sources are always `:latest`. Use `rad` instead:

- `rad init --preview` always rewrites the default pack from the pack built into that `rad` version. It also creates or updates the Environment you choose during init.
- `rad env create --preview` without `--recipe-packs`, and `rad deploy` of a template whose Environment sets no `recipePacks`, create the default pack only when it is missing; they never update an existing pack. Delete the pack first, then run one of them, for example by creating a new Environment:

  ```bash
  rad recipe-pack delete default --group default --yes
  rad env create <new-env-name> --preview
  ```

  Environments that `rad init --preview` or `rad env create` linked to the default pack keep its ID and use the recreated pack. `rad recipe-pack delete` removes the pack from the Environments listed in its `referencedBy`, which are the ones linked with `--recipe-packs`. Re-link each of those:

  ```bash
  rad env update <env-name> \
    --group <environment-group> \
    --recipe-packs default \
    --recipe-pack-group default \
    --preview
  ```

## Contributing a Recipe

To add a Recipe for another Resource Type to this pack, add an entry to the `recipes` map keyed by the Resource Type (for example `Radius.Data/mySqlDatabases`). For guidance on writing Recipes and wiring them into a Recipe Pack, see [Contributing Resource Types and Radius Recipes](../../docs/contributing/contributing-resource-types-recipes.md#recipes-and-recipe-packs).
