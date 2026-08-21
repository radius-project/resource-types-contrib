# Azure Recipe Pack

This folder contains the **Azure Recipe Pack** — a collection of Recipes that provision Radius Resource Types on Azure, bundled with an Environment definition. Deploying the pack configures a Radius Environment to use the Azure provider and registers the Recipes for every Resource Type it covers.

| File | Description |
| --- | --- |
| `aks-recipepack.bicep` | Recipe Pack wiring the Bicep recipes for all Azure-provisioned types, plus the Environment definition. |

Each pack declares a `Radius.Core/recipePacks` resource whose `recipes` map contains an entry for every Resource Type, and a `Radius.Core/environments` resource that references the pack and configures the Azure provider.

## Azure resource naming

Some Azure services require names that are unique across Azure, so their Recipes combine a short service prefix with `{{context.azure.resourceNameHash}}`. The expression returns the first 16 lowercase hexadecimal characters of a SHA-256 hash over the lowercased Azure resource-group ID and Radius resource ID. The same resource in the same resource group keeps its name across deployments, while changing either ID produces a different name.

This Recipe Pack requires a Radius runtime that supports the `context.azure.resourceNameHash` direct-module expression. Earlier revisions used `context.resource.name` directly, and adopting this revision changes those Azure resource names, which may cause existing edge deployments to provision replacement resources.

## Database ports

The AVM modules for MySQL flexible server, PostgreSQL flexible server, and Azure SQL Database expose `fqdn` / `fullyQualifiedDomainName` but no port output, so this pack maps only `host` for `Radius.Data/mySqlDatabases`, `Radius.Data/postgreSqlDatabases`, and `Radius.Data/sqlServerDatabases`.

A Recipe Pack `outputs` entry maps a resource property to the **name of a module output**; it cannot supply a literal, and naming an output the module does not declare fails validation before the deployment is submitted. Because each of these Azure managed services is fixed to its engine's standard port, each Resource Type declares `port` as an optional property whose schema default is that port (`3306`, `5432`, `1433`). Radius materializes the default when the application definition leaves the property unset, so `CONNECTION_<NAME>_PORT` is populated on Azure without a mapping here. Please do not "fix" the missing mapping by adding a `port` entry to these recipes.

Materializing schema defaults requires Radius v0.60.0 or later, and requires the `Radius.Data` namespace registered in the cluster to be new enough to declare the `port` default. This pack does not register Resource Types, so deploying it against an older registered namespace leaves `port` unset exactly as before.

Defaults are applied when a resource is written, not when a Resource Type is registered, so recovering an existing Environment takes three steps:

1. Register a current `Radius.Data` namespace.
2. Redeploy the application, so each database resource is written again and picks up the default.
3. Redeploy or restart the connected containers, so their environment variables are refreshed.

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

### MySQL versions

The `Radius.Data/mySqlDatabases` Recipe preserves the requested MySQL major version. The Resource Type's `8.0` value maps to the Azure module's `8.0.21` version token; `5.7` and `8.4` map directly to the corresponding Azure versions.

### MySQL transport policy

The `Radius.Data/mySqlDatabases` Recipe maps the resource's `tls` property onto the flexible server's `require_secure_transport` parameter, so the server rejects connections that do not use TLS unless the application sets `tls: 'optional'`. This relies on the Radius runtime materializing schema defaults into the resource's properties, so applications that omit `tls` still resolve to `required`.

This Recipe therefore requires a registered `Radius.Data` namespace whose `mySqlDatabases` definition includes the `tls` property. The property was added without changing the `2025-08-01-preview` API version, so an older definition cannot be detected by version negotiation. If this pack is used against one, `tls` resolves to nothing and MySQL provisioning fails with an Azure error reporting an unresolved `{{context.resource.properties.tls ...}}` value for `require_secure_transport`. Register a `Radius.Data` namespace release that contains the property before deploying this pack.

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
