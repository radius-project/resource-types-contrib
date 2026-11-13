# Kubernetes Recipe Pack

This folder contains the **Kubernetes Recipe Pack** — a collection of Recipes that provision Radius Resource Types on Kubernetes. Deploying the pack creates only a reusable `Radius.Core/recipePacks` resource. Create the target Radius Environment separately, then associate the pack with it.

| File | Description |
| --- | --- |
| `default.bicep` | Recipe Pack wiring the Bicep recipes for all Kubernetes-provisioned types. |

The pack declares one `Radius.Core/recipePacks` resource for the non-AI default types that can run on Kubernetes. It does not create or modify a `Radius.Core/environments` resource. AI services and non-default types are outside this pack.

**PostgreSQL TLS:** Both transport policies enable TLS. An absent or empty `<resource-name>-tls` Secret selects a generated self-signed development certificate. For verified identity, supply an operator certificate and configure clients to trust its CA. Invalid supplied material fails initialization, and the Recipe never deletes the operator Secret. See [Kubernetes TLS](../../Data/postgreSqlDatabases/README.md#kubernetes-tls) for setup, verification, migration, and manual rotation.

## Recipes in this pack

Kube-recipes tagged `:edge` are rebuilt on every push to `main`. `:latest` and the version tags track stable releases, but `:latest` moves to a new digest each time a release publishes, so pin a version tag if you need a reproducible deployment.

| Resource Type | Kind | Source |
| --- | --- | --- |
| `Radius.Compute/containers` | Bicep | `ghcr.io/radius-project/kube-recipes/containers:latest` |
| `Radius.Compute/persistentVolumes` | Bicep | `ghcr.io/radius-project/kube-recipes/persistentvolumes:latest` |
| `Radius.Compute/routes` | Bicep | `ghcr.io/radius-project/kube-recipes/routes:latest` |
| `Radius.Security/secrets` | Bicep | `ghcr.io/radius-project/kube-recipes/secrets:latest` |
| `Radius.Data/mySqlDatabases` | Bicep | `ghcr.io/radius-project/kube-recipes/mysqldatabases:latest` |
| `Radius.Data/mongoDatabases` | Bicep | `ghcr.io/radius-project/kube-recipes/mongodatabases:latest` |
| `Radius.Data/postgreSqlDatabases` | Bicep | `ghcr.io/radius-project/kube-recipes/postgresqldatabases:latest` |
| `Radius.Data/redisCaches` | Bicep | `ghcr.io/radius-project/kube-recipes/rediscaches:latest` |
| `Radius.Data/sqlServerDatabases` | Bicep | `ghcr.io/radius-project/kube-recipes/sqlserverdatabases:latest` |
| `Radius.Messaging/kafka` | Bicep | `ghcr.io/radius-project/kube-recipes/kafka:latest` |
| `Radius.Messaging/rabbitMQ` | Bicep | `ghcr.io/radius-project/kube-recipes/rabbitmq:latest` |
| `Radius.Storage/objectStorage` | Bicep | `ghcr.io/radius-project/kube-recipes/objectstorage:latest` |

`rad init` and `rad env create` (without `--recipe-packs`) link Radius's built-in default pack, `/planes/radius/local/resourceGroups/default/providers/Radius.Core/recipePacks/default`. Current Radius source builds embed the compiled pack selected by `recipePacks[].ref` in `deploy/manifest/defaults.yaml`; they do not fetch this working copy at runtime. The CLI pins each recipe source to its namespace's resource-types-contrib commit for that Radius release (`:edge` for edge builds). Older CLI releases can contain a smaller pack. **Deploying this file to the same pack ID overwrites the built-in pack for every Environment that references it and switches all of its sources to `:latest`.** To get the built-in pack back, see [Restoring Radius's default pack](#restoring-radiuss-default-pack).

In Radius 0.61 and earlier, `rad init` and `rad env create` target `Radius.Core` only with `--preview`. Add `--preview` to the `rad init` and `rad env create` commands in this README when you use those versions.

## Service prerequisites

These are development services, not managed production services. Check each Recipe's README before use. Kafka uses a single broker with plaintext transport. Object storage uses the Azurite Blob emulator over HTTP, not an S3 endpoint or the full Azure Storage service. Persistent services need a suitable storage provisioner and enough capacity. Deploying the pack registers recipes only; it does not create their workloads, credentials, or volumes.

### Operator-owned credentials

MongoDB and objectStorage Bicep Recipes read existing Kubernetes Secrets. Create them in the namespace used by the resource's Recipe context (`context.runtime.kubernetes.namespace`) before deploying that resource:

| Resource | Recipe parameter | Default Secret name | Required key |
| --- | --- | --- | --- |
| MongoDB | `mongoCredentialsSecretName` | `<resource-name>-mongodb-credentials` | `password`: at least 16 characters |
| objectStorage | `objectStorageCredentialsSecretName` | `<resource-name>-blob-credentials` | `accountKey`: base64 encoding of 64 random bytes |

Use your secret manager or restricted local files. For example, with existing files that contain only the required value and no trailing newline:

```bash
kubectl create secret generic <resource-name>-mongodb-credentials \
  --namespace <recipe-namespace> \
  --from-file=password=<protected-password-file>
kubectl create secret generic <resource-name>-blob-credentials \
  --namespace <recipe-namespace> \
  --from-file=accountKey=<protected-account-key-file>
```

`--from-file` adds Kubernetes' base64 encoding. The object storage file must itself contain the base64 account key, not raw random bytes. Do not copy secret files into this repository.

Keep the Secrets stable when you deploy a resource again. The operator owns backup and rotation; resource cleanup must not delete these supplied Secrets. MongoDB password changes need the database's rotation procedure, not only a Secret update. See [MongoDB](../../Data/mongoDatabases/README.md) and [objectStorage](../../Storage/objectStorage/README.md) for the Recipe contracts and rotation limits.

The pack stores no password or account key. Bicep secret inputs must use `@secure()`, but that annotation does not protect a value copied into a stored `RecipePack.parameters` property. Store only Secret names in Recipe configuration. Do not add a generated password as a pack default.

### SQL Server license consent

Registering this pack does **not** accept Microsoft's SQL Server license. The SQL Server Recipe requires `sqlServerAcceptEula: 'Y'` with no default. Read the [SQL Server Recipe requirements](../../Data/sqlServerDatabases/README.md) first. Only after accepting the terms, add this per-type override to the Environment's existing `properties.recipeParameters`:

```bicep
recipeParameters: {
  'Radius.Data/sqlServerDatabases': {
    sqlServerAcceptEula: 'Y'
  }
}
```

Merge the override with the Environment's existing configuration; do not replace its providers or pack references. Without this explicit setting, SQL Server deployment fails rather than accepting a license for you. Other types do not need this setting. Automated Kubernetes tests skip SQL Server unless the operator sets `RTC_SQLSERVER_ACCEPT_EULA=Y`; pack deployment alone is not consent. To run checked-in pack entry tests with that opt-in, also configure the override on the dedicated test Environment. The runner does not change Environment license settings.

## Terraform alternatives

Each listed type also has a Terraform Recipe at `<Category>/<resourceType>/recipes/kubernetes/terraform`. To use it, replace that type's Bicep entry in a copy of the pack with a Terraform Git source:

```bicep
'Radius.Data/redisCaches': {
  kind: 'terraform'
  source: 'git::https://github.com/radius-project/resource-types-contrib.git//Data/redisCaches/recipes/kubernetes/terraform?ref=<full-commit-sha>'
}
```

Select a commit that contains the required module and its fixes, and replace `<full-commit-sha>` with that commit. Use the same path pattern for the other types in the table. The Radius worker needs Git and network access to GitHub and the provider registries. A namespace release archive does not contain these modules. The test module server's cluster-local ZIP URLs are not public Recipe sources.

Keep one entry per Resource Type; do not attach overlapping Bicep and Terraform packs to the same Environment. Terraform-generated credentials are retained in state: protect and back up that state. Switching an existing resource between Bicep and Terraform is not an in-place migration; use a new resource and migrate its data. SQL Server still requires explicit license consent.

## Publication prerequisites

Before deploying or releasing this pack, confirm every referenced Recipe is public and available at `:latest`:

```bash
RECIPE_PACK=kubernetes bash .github/scripts/release/verify-recipe-pack-sources.sh
```

The four new Recipe sources are `mongodatabases`, `sqlserverdatabases`, `kafka`, and `objectstorage`. Their source PRs must merge before the publication workflow can build them. A push to `main` publishes commit and `:edge` tags, not `:latest`. Stable publication must follow the [Recipe publication lifecycle](../README.md#release-readiness); a pack release or namespace release alone does not advance `:latest`. Verify that the MongoDB and objectStorage artifacts include the existing-Secret contract, not an earlier raw-credential input.

## Prerequisite: `bicepconfig.json`

`rad deploy` needs a `bicepconfig.json` that registers the `radius` extension. This repo does not commit one. Before deploying, create one above `recipe-packs/` (Bicep looks for `bicepconfig.json` by walking up from the `.bicep` file's directory, not your current directory), for example:

```json
{
  "extensions": {
    "radius": "br:biceptypes.azurecr.io/radius:<rad-release-channel>"
  }
}
```

Replace `<rad-release-channel>` with the major and minor version of your `rad` CLI (for example `0.61` for `rad` 0.61.1), or `latest` for edge builds. A full version such as `0.61.1` is not a valid tag. `rad init` writes a similar file that also registers the `aws` extension.

## Deploying

Create the Environment first:

```bash
rad env create default \
  --kubernetes-namespace default
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
  --recipe-pack-group default
```

After the association is confirmed, every Resource Type the pack covers can be used in an application deployed to that Environment.

## Restoring Radius's default pack

Deploying this file cannot restore the exact pack Radius creates, because its sources are always `:latest`. Use `rad` instead:

- `rad init` always rewrites the default pack from the pack built into that `rad` version. It also creates or updates the Environment you choose during init.
- `rad env create` without `--recipe-packs`, and `rad deploy` of a template whose Environment sets no `recipePacks`, create the default pack only when it is missing; they never update an existing pack. To use one of them, delete the pack first.

  `rad recipe-pack delete` removes the pack from each Environment in the pack's `referencedBy` list. Before you delete the pack, record the Environments in that list:

  ```bash
  rad recipe-pack show default --group default -o json
  ```

  `rad env create` and `rad env update` add an Environment to `referencedBy` only when you link the pack with `--recipe-packs`. A full write of the pack, such as `rad deploy` of this file or `rad init`, clears the list. Thus, after you deploy this file, the list is usually empty.

  Delete the pack, then recreate it, for example by creating a new Environment:

  ```bash
  rad recipe-pack delete default --group default --yes
  rad env create <new-env-name>
  ```

  Environments that are not in `referencedBy` keep the pack ID and use the recreated pack. Re-link each Environment that was in `referencedBy`:

  ```bash
  rad env update <env-name> \
    --group <environment-group> \
    --recipe-packs default \
    --recipe-pack-group default
  ```

## Contributing a Recipe

To add a Recipe for another Resource Type to this pack, add an entry to the `recipes` map keyed by the Resource Type (for example `Radius.Data/mySqlDatabases`). For guidance on writing Recipes and wiring them into a Recipe Pack, see [Contributing Resource Types and Radius Recipes](../../docs/contributing/contributing-resource-types-recipes.md#recipes-and-recipe-packs).
