# Azure Recipe Pack

This folder contains the **Azure Recipe Pack** — a collection of Recipes that provision Radius Resource Types on Azure, bundled with an Environment definition. Deploying the pack configures a Radius Environment to use the Azure provider and registers the Recipes for every Resource Type it covers.

| File | Description |
| --- | --- |
| `aks-recipepack.bicep` | Recipe Pack wiring the Bicep recipes for all Azure-provisioned types, plus the Environment definition. |

Each pack declares a `Radius.Core/recipePacks` resource whose `recipes` map contains an entry for every Resource Type, and a `Radius.Core/environments` resource that references the pack and configures the Azure provider.

## Azure resource naming

Some Azure services require names that are unique across Azure, so their Recipes combine a short service prefix with `{{context.azure.resourceNameHash}}`. The expression returns the first 16 lowercase hexadecimal characters of a SHA-256 hash over the lowercased Azure resource-group ID and Radius resource ID. The same resource in the same resource group keeps its name across deployments, while changing either ID produces a different name.

This Recipe Pack requires a Radius runtime that supports the `context.azure.resourceNameHash` direct-module expression. Earlier revisions used `context.resource.name` directly, and adopting this revision changes those Azure resource names, which may cause existing edge deployments to provision replacement resources.

## Recipes in this pack

| Resource Type | Kind | Source |
| --- | --- | --- |
| `Radius.Data/sqlServerDatabases` | Bicep | Azure Verified Module — `mcr.microsoft.com/bicep/avm/res/sql/server:0.21.4` |
| `Radius.Data/postgreSqlDatabases` | Bicep | Azure Verified Module — `avm/res/db-for-postgre-sql/flexible-server` |
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
| `postgreSqlServerConfigurations` | Server parameters forwarded verbatim to the AVM PostgreSQL flexible server `configurations` array for `Radius.Data/postgreSqlDatabases`, using the AVM item shape `{ name, value }` with an optional `source` field. Defaults to `[{ name: 'require_secure_transport', value: 'ON' }]`, preserving the flexible server's default so existing deployments keep requiring TLS. Also commonly used to allow-list extensions via `azure.extensions` — for example `[{ name: 'require_secure_transport', value: 'ON' }, { name: 'azure.extensions', source: 'user-override', value: 'vector' }]` to enable pgvector while keeping the default TLS behavior — or to disable `require_secure_transport` so `Radius.Data/postgreSqlDatabases` matches the Kubernetes Recipe for this Resource Type, whose `sslMode` output is always `disabled` (see [issue #301](https://github.com/radius-project/resource-types-contrib/issues/301)). See [Extensions and modules by name in Azure Database for PostgreSQL flexible server](https://learn.microsoft.com/en-us/azure/postgresql/extensions/concepts-extensions-versions) for the supported extension names. Optional. |
| `mySqlServerConfigurations` | Server parameters forwarded verbatim to the AVM MySQL flexible server `configurations` array for `Radius.Data/mySqlDatabases`, using the AVM item shape `{ name, value }` with an optional `source` field. Defaults to `[{ name: 'require_secure_transport', value: 'ON' }]`, preserving the flexible server's default so existing deployments keep requiring TLS. Override to disable `require_secure_transport` so `Radius.Data/mySqlDatabases` matches the Kubernetes and AWS Recipes for this Resource Type, whose `sslMode` output is always `disabled` (see [issue #301](https://github.com/radius-project/resource-types-contrib/issues/301)). Optional. |

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
