# Azure Recipe Pack

This folder contains the **Azure Recipe Pack** — a collection of Recipes that provision Radius Resource Types on Azure, bundled with an Environment definition. Deploying the pack configures a Radius Environment to use the Azure provider and registers the Recipes for every Resource Type it covers.

| File | Description |
| --- | --- |
| `aks-recipepack.bicep` | Recipe Pack wiring the Bicep recipes for all Azure-provisioned types, plus the Environment definition. |

Each pack declares a `Radius.Core/recipePacks` resource whose `recipes` map contains an entry for every Resource Type, and a `Radius.Core/environments` resource that references the pack and configures the Azure provider.

## Azure resource naming

Some Azure services require names that are unique across Azure, so their Recipes combine a short service prefix with `{{context.azure.resourceNameHash}}`. The expression returns the first 16 lowercase hexadecimal characters of a SHA-256 hash over the lowercased Azure resource-group ID and Radius resource ID. The same resource in the same resource group keeps its name across deployments, while changing either ID produces a different name.

This Recipe Pack requires a Radius runtime that supports the `context.azure.resourceNameHash` direct-module expression. Earlier revisions used `context.resource.name` directly, and adopting this revision changes those Azure resource names, which may cause existing edge deployments to provision replacement resources.

## Azure naming constraints

Several Recipes in this pack pass a developer-supplied property straight through as the name of an
Azure child resource or as an administrator login. Azure enforces its own rules on those values, so
a name Radius accepts can still fail the deployment — historically *after* the parent server or
storage account had been created and billed.

From API version `2026-09-01-preview` the affected Resource Types constrain these properties in
their schemas, so Radius rejects a malformed value at submission time, before any Recipe runs.
Resources still using `2025-08-01-preview` are unconstrained and behave as before.

| Resource Type | Property | Becomes | Accepted format |
| --- | --- | --- | --- |
| `Radius.Data/postgreSqlDatabases` | `database` | flexible server child database | 1-63; starts with a letter or underscore, then letters, digits, underscores |
| `Radius.Data/postgreSqlDatabases` | `username` | `administratorLogin` | 1-63 letters and digits only |
| `Radius.Data/mySqlDatabases` | `database` | flexible server child database | 1-63; starts with a letter, then letters, digits, underscores |
| `Radius.Data/mySqlDatabases` | `username` | `administratorLogin` | 1-16; starts with a letter, then letters, digits, underscores (AWS RDS limit, stricter than Azure's 32) |
| `Radius.Data/sqlServerDatabases` | `database` | SQL Server child database | 1-128; no `< > * % & : \ / ?` or control characters; no trailing period or space |
| `Radius.Data/sqlServerDatabases` | `username` | `administratorLogin` | 1-128; starts with a letter, then letters, digits, underscores |
| `Radius.Data/mongoDatabases` | `database` | Cosmos DB Mongo database | 1-63; no spaces, control characters or ``/ \ . " $ * < > : | ? #`` |
| `Radius.Messaging/kafka` | `topic` | Event Hub | 1-249 of letters, digits, `.`, `_`, `-`; starts and ends alphanumeric |
| `Radius.Storage/objectStorage` | `containerName` | blob container | 3-63 lowercase letters, digits and single hyphens; starts and ends alphanumeric |

Each Resource Type README documents the rule and any reserved names in full.

### Reserved names are not covered

A schema constraint can describe a *format*, but it cannot exclude a specific value: Radius rejects
the `not` and `oneOf` keywords when a Resource Type is registered, and its pattern engine has no
negative lookahead. Names such as `master` on SQL Server or `azure_superuser` on MySQL therefore
still reach the provider and still fail there. They are documented per Resource Type, and
[radius-project/radius](https://github.com/radius-project/radius) is asked to add a denylist
mechanism so they can be caught at submission time too.

The one exception is `Radius.Data/postgreSqlDatabases` with `database: 'postgres'`, the case
reported in issue #299. Azure pre-creates a `postgres` database on every flexible server, so the
pack's old inline AVM reference asked Azure to create it twice and failed. That Resource Type now
points at an authored Recipe,
[`Data/postgreSqlDatabases/recipes/azure/bicep/azure-postgresql.bicep`](../../Data/postgreSqlDatabases/recipes/azure/bicep/azure-postgresql.bicep),
which provisions the server with no child database in that case and binds the application to the
one Azure already created. The Recipe reproduces the pack's `pgsql-{{context.azure.resourceNameHash}}`
server name exactly, so existing deployments are not renamed.

## Recipes in this pack

| Resource Type | Kind | Source |
| --- | --- | --- |
| `Radius.Data/sqlServerDatabases` | Bicep | Azure Verified Module — `mcr.microsoft.com/bicep/avm/res/sql/server:0.21.4` |
| `Radius.Data/postgreSqlDatabases` | Bicep | `ghcr.io/radius-project/azure-recipes/postgresqldatabases`, which wraps the Azure Verified Module `avm/res/db-for-postgre-sql/flexible-server` |
| `Radius.AI/search` | Bicep | Azure Verified Module — `avm/res/search/search-service` |
| `Radius.AI/models` | Bicep | Azure Verified Module — `avm/res/cognitive-services/account` |
| `Radius.Messaging/rabbitMQ` | Bicep | `ghcr.io/radius-project/kube-recipes/rabbitmq` |
| `Radius.Messaging/kafka` | Bicep | Azure Verified Module — `avm/res/event-hub/namespace` |
| `Radius.Data/mongoDatabases` | Bicep | Azure Verified Module — `avm/res/document-db/database-account` |
| `Radius.Data/mySqlDatabases` | Bicep | Azure Verified Module — `avm/res/db-for-my-sql/flexible-server` |
| `Radius.Data/redisCaches` | Bicep | Azure Verified Module — `avm/res/cache/redis-enterprise` |
| `Radius.Storage/objectStorage` | Bicep | Azure Verified Module — `avm/res/storage/storage-account` |
| `Radius.Compute/containers` | Bicep | `ghcr.io/radius-project/kube-recipes/containers` |
| `Radius.Compute/persistentVolumes` | Bicep | `ghcr.io/radius-project/kube-recipes/persistentvolumes` |
| `Radius.Security/secrets` | Bicep | `ghcr.io/radius-project/kube-recipes/secrets` |
| `Radius.Compute/routes` | Bicep | `ghcr.io/radius-project/kube-recipes/routes` |
| `Radius.Compute/containerImages` | Bicep | `ghcr.io/radius-project/kube-recipes/containerimages` |

## Parameters

The Azure pack accepts the provider configuration it needs to provision into your subscription:

| Parameter | Description |
| --- | --- |
| `environmentName` | Name of the Radius Environment to create. Defaults to `default`. |
| `environmentNamespace` | Kubernetes namespace the Radius Environment deploys resources into. Defaults to `default`. |
| `azureSubscriptionId` | Azure subscription ID the Environment provisions resources into. |
| `azureResourceGroup` | Existing Azure resource group the Environment provisions resources into. |
| `routesGatewayName` | Name of the existing Kubernetes Gateway resource that `Radius.Compute/routes` attach to. |
| `routesGatewayNamespace` | Namespace of the Gateway resource for `Radius.Compute/routes`. Defaults to `default`. |
| `containerImagesRegistry` | Registry path (e.g. `ghcr.io/my-org`) that `Radius.Compute/containerImages` pushes built images to. |
| `containerImagesRegistrySecretName` | Name of the Kubernetes Secret holding registry credentials for `Radius.Compute/containerImages`. Optional; leave empty for an unauthenticated registry. |
| `postgreSqlServerConfigurations` | Server parameters forwarded verbatim to the AVM PostgreSQL flexible server `configurations` array for `Radius.Data/postgreSqlDatabases`, using the AVM item shape `{ name, source, value }`. Most commonly used to allow-list extensions via `azure.extensions` — for example `[{ name: 'azure.extensions', source: 'user-override', value: 'vector' }]` to enable pgvector. See [Extensions and modules by name in Azure Database for PostgreSQL flexible server](https://learn.microsoft.com/en-us/azure/postgresql/extensions/concepts-extensions-versions) for the supported extension names. Optional; defaults to an empty array (no extra server configuration). |

## Deploying

Deploy the pack with the `rad` CLI, supplying the parameters it requires. Deploying the file creates the `Radius.Core/recipePacks` resource and configures the `default` Environment to use it:

```bash
rad deploy recipe-packs/azure/aks-recipepack.bicep \
  --parameters azureSubscriptionId=<subscription-id> \
  --parameters azureResourceGroup=<resource-group> \
  --parameters routesGatewayName=<gateway-name> \
  --parameters containerImagesRegistry=<registry-path>
```

After the pack is deployed, every Resource Type it covers can be used in an application deployed to that Environment.

## Contributing a Recipe

To add a Recipe for another Resource Type to this pack, add an entry to the `recipes` map keyed by the Resource Type (for example `Radius.Data/mySqlDatabases`). For guidance on writing Recipes and wiring them into a Recipe Pack, see [Contributing Resource Types and Radius Recipes](../../docs/contributing/contributing-resource-types-recipes.md#recipes-and-recipe-packs).
