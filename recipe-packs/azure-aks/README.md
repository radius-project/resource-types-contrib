# Azure AKS Recipe Pack

This folder contains the **Azure AKS Recipe Pack** — a collection of Recipes that provision Radius Resource Types on Azure, running containers on Azure Kubernetes Service (AKS). Deploying the pack creates only a reusable `Radius.Core/recipePacks` resource. Create and configure the target Radius Environment separately, then associate the pack with it.

| File | Description |
| --- | --- |
| `azure-aks.bicep` | Recipe Pack wiring the Bicep recipes for all Azure-provisioned types. |

The pack declares one `Radius.Core/recipePacks` resource whose `recipes` map contains an entry for every Resource Type. It does not create or modify a `Radius.Core/environments` resource.

## Azure resource naming

Some Azure services require names that are unique across Azure, so their Recipes combine a short service prefix with `{{context.azure.resourceNameHash}}`. The expression returns the first 16 lowercase hexadecimal characters of a SHA-256 hash over the lowercased Azure resource-group ID and Radius resource ID. The same resource in the same resource group keeps its name across deployments, while changing either ID produces a different name.

This Recipe Pack requires a Radius runtime that supports the `context.azure.resourceNameHash` direct-module expression. Earlier revisions used `context.resource.name` directly, and adopting this revision changes those Azure resource names, which may cause existing edge deployments to provision replacement resources.

The authored PostgreSQL Recipe reads `context.azure.resourceNameHash` inside
the Recipe and adds the `pgsql-` prefix. The pack does not pass a
`{{context.*}}` name override because Radius does not resolve these expressions
for Recipes that accept `context`. See the [PostgreSQL naming defaults](../../Data/postgreSqlDatabases/recipes/azure/README.md)
for the fallback when the runtime hash is absent.

## Database ports

The direct AVM modules for MySQL flexible server and Azure SQL Database expose `fqdn` / `fullyQualifiedDomainName` but no port output, so this pack maps only `host` for `Radius.Data/mySqlDatabases` and `Radius.Data/sqlServerDatabases`. The authored PostgreSQL Recipe returns `host`, `port: 5432`, and `database` through its `result`.

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
| `Radius.Data/postgreSqlDatabases` | Bicep | `ghcr.io/radius-project/azure-aks-recipes/postgresqldatabases:latest`, using AVM `avm/res/db-for-postgre-sql/flexible-server:0.15.2` |
| `Radius.AI/search` | Bicep | Azure Verified Module — `avm/res/search/search-service` |
| `Radius.AI/models` | Bicep | `ghcr.io/radius-project/azure-recipes/models` |
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

### OpenAI account keys

The `Radius.AI/models` Recipe completes the AVM account module and its key
outputs before it starts the `chat` model deployment. This prevents concurrent
account key reads and model provisioning, without a test retry or an AVM version
change. The Recipe uses the same account name and model settings as the previous
direct-module entry. It returns the endpoint and API key through the standard
Recipe result, with the key in `result.secrets.apiKey`.

### MySQL versions

The `Radius.Data/mySqlDatabases` Recipe preserves the requested MySQL major version. The Resource Type's `8.0` value maps to the Azure module's `8.0.21` version token; `5.7` and `8.4` map directly to the corresponding Azure versions.

### MySQL transport policy

The `Radius.Data/mySqlDatabases` Recipe maps the resource's `tls` property onto the flexible server's `require_secure_transport` parameter, so the server rejects connections that do not use TLS unless the application sets `tls: 'optional'`. This relies on the Radius runtime materializing schema defaults into the resource's properties, so applications that omit `tls` still resolve to `required`.

**Keep TLS required with this pack as written.** It enables public network access and includes an allow-all firewall rule, with no parameter to make the server private. Setting `tls: 'optional'` permits non-TLS connections that can expose administrator credentials and query traffic in transit. Use `optional` only with a Recipe or customized pack that makes the server not publicly reachable. Private reachability does not encrypt traffic, so TLS remains preferred. `optional` allows plaintext; it does not disable TLS support or change network access.

This Recipe therefore requires a registered `Radius.Data` namespace whose `mySqlDatabases` definition includes the `tls` property. The property was added without changing the `2025-08-01-preview` API version, so an older definition cannot be detected by version negotiation. Register a `Radius.Data` namespace release that contains the property before deploying this pack.

### PostgreSQL transport policy

The `Radius.Data/postgreSqlDatabases` Recipe uses the resource's `tls` property and operator configuration to set the server transport policy. See the [Azure configuration rules](../../Data/postgreSqlDatabases/recipes/azure/README.md#settings-and-operator-overrides) for the mapping and operator precedence.

**Keep TLS required with this pack as written.** It enables public network access and includes an allow-all firewall rule, with no parameter to make the server private. Allowing non-TLS connections can expose administrator credentials and query traffic in transit. Use `optional` only with a Recipe or customized pack that makes the server not publicly reachable. Private reachability does not encrypt traffic, so TLS remains preferred. `optional` allows plaintext when honored by the Recipe; it does not disable TLS support or change network access.

The PostgreSQL operator-configuration array does not apply to the MySQL Recipe.

This Recipe therefore requires a registered `Radius.Data` namespace whose `postgreSqlDatabases` definition includes the `tls` property. The property was added without changing the `2025-08-01-preview` API version, so an older definition cannot be detected by version negotiation. Register a `Radius.Data` namespace release that contains the property before deploying this pack.

### PostgreSQL application settings

Applications can now request `extensions` and `serverSettings` on
`Radius.Data/postgreSqlDatabases`. The authored Recipe converts the
application map and list to AVM configuration items. It still uses the
same pinned `flexible-server:0.15.2` AVM and retains the existing server
name and provisioning defaults; it does not replace AVM provisioning.

See the [Azure configuration rules](../../Data/postgreSqlDatabases/recipes/azure/README.md#settings-and-operator-overrides)
for extension list merging, explicit clearing, operator precedence, and
protected settings.

**Release prerequisite:** Public availability of the new
`ghcr.io/radius-project/azure-aks-recipes/postgresqldatabases:latest`
image is not verified. Publish it through the normal release process and
verify anonymous pull access before releasing or deploying this pack.
The publishing workflow adds the Recipe, but a main-branch `edge` push
does not establish the `latest` alias. No stable alias or package access
change is part of this change. See the [Recipe documentation](../../Data/postgreSqlDatabases/recipes/azure/README.md).

## Parameters

The Azure pack accepts only parameters consumed by its Recipes. Azure and Kubernetes provider settings belong to the target Environment and are configured separately.

| Parameter | Description |
| --- | --- |
| `routesGatewayName` | Name of the existing Kubernetes Gateway resource that `Radius.Compute/routes` attach to. |
| `routesGatewayNamespace` | Namespace of the Gateway resource for `Radius.Compute/routes`. Defaults to `default`. |
| `containerImagesRegistry` | Registry path (e.g. `ghcr.io/my-org`) that `Radius.Compute/containerImages` pushes built images to. |
| `containerImagesRegistrySecretName` | Name of the Kubernetes Secret holding registry credentials for `Radius.Compute/containerImages`. Optional; leave empty for an unauthenticated registry. |
| `postgreSqlServerConfigurations` | Operator settings in AVM `{ name, source, value }` form. Defaults to `[]`. See the [Azure configuration rules](../../Data/postgreSqlDatabases/recipes/azure/README.md#settings-and-operator-overrides). |

## Deploying

Create and configure the Environment first:

```bash
rad env create default \
  --kubernetes-namespace default

rad env update default \
  --azure-subscription-id <subscription-id> \
  --azure-resource-group <resource-group>
```

Deploy the Recipe Pack into that existing Environment, supplying only Recipe parameters:

```bash
rad deploy recipe-packs/azure-aks/azure-aks.bicep \
  --environment default \
  --parameters routesGatewayName=<gateway-name> \
  --parameters containerImagesRegistry=<registry-path>
```

Finally, associate the pack with the Environment:

```bash
rad env update default \
  --recipe-packs azure-aks
```

After the association is updated, every Resource Type the pack covers can be used in an application deployed to that Environment.

## Migrating from the Azure pack

The former `recipe-packs/azure/aks-recipepack.bicep` deployed a pack named
`azure-avm`. Its replacement is `recipe-packs/azure-aks/azure-aks.bicep`, which
deploys a separate pack named `azure-aks`. Existing Environment associations
are not renamed automatically.

1. Record each Environment's current pack list and Recipe parameter values.
   Review the runtime, namespace, and resource-naming prerequisites above
   before upgrading an existing deployment.
2. Deploy `azure-aks.bicep` as shown above, supplying the existing Gateway,
   registry, and any optional Recipe parameter values.
3. Update each intended Environment with `rad env update <environment> --recipe-packs azure-aks`.
   This replaces the entire pack list; include any other previously associated,
   non-overlapping packs that must remain. Do not associate both `azure-avm`
   and `azure-aks`, because their Resource Types overlap.
4. Verify application deployment and connections in the target Environment.
   Keep the old pack until no Environment references it and the migration is
   verified; changing the association alone does not migrate Azure resources.

Release tags also have a new identity: `recipe-pack/azure-aks/v...` starts its
own series, rather than continuing `recipe-pack/azure/v0.3.0`. A first minor
bump resolves to `0.1.0`; it does not mean the old pack was downgraded. Retain
the historical `recipe-pack/azure/v...` tags and releases for existing consumers.
Update any automation that selects the old directory, filename, pack name, or
release prefix explicitly.

## Contributing a Recipe

To add a Recipe for another Resource Type to this pack, add an entry to the `recipes` map keyed by the Resource Type (for example `Radius.Data/mySqlDatabases`). For guidance on writing Recipes and wiring them into a Recipe Pack, see [Contributing Resource Types and Radius Recipes](../../docs/contributing/contributing-resource-types-recipes.md#recipes-and-recipe-packs).
