# Azure PostgreSQL Recipe

This Recipe converts the application's `serverSettings` map and `extensions`
list to the `configurations` array that Azure Verified Module
`avm/res/db-for-postgre-sql/flexible-server:0.15.2` accepts. Direct-module
mapping cannot perform this conversion and merge operator overrides. The
Recipe still uses the same pinned AVM to provision the server. It retains
the Azure AKS pack's server name, version, sizes, storage, authentication,
and network defaults.

The inputs are the Radius `context`, an optional stable Azure
`postgreSqlServerName`, and an optional operator
`postgreSqlServerConfigurations` array in AVM `{ name, source, value }`
form. The pack supplies its existing hash-based server name. A standalone
Recipe derives a name from the Azure subscription, resource group, and
Radius resource ID. Repeated deployments in the same scope keep the name;
different Azure scopes get different names.

## Settings and operator overrides

Operator entries take precedence over matching application `serverSettings`.
Comparisons ignore name case, as required by the
[Azure resource naming rules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules).
Other setting names and values are forwarded unchanged. Use canonical
lowercase names in configuration. Malformed or unsupported settings fail
compilation or deployment.

The application must use the dedicated `extensions` and `tls` properties.
Generic `serverSettings` entries for `azure.extensions`,
`require_secure_transport`, and `port` are ignored, without regard to case.
All operator `port` entries are also ignored; the server stays on port 5432.

The `extensions` list requests the server's `azure.extensions` allow-list.
Use [extensions supported by Azure](https://learn.microsoft.com/en-us/azure/postgresql/extensions/concepts-extensions-versions);
the application must create each extension in its database. When the operator
also supplies a nonempty `azure.extensions` value, the Recipe combines both
lists. It trims spaces and removes duplicates without regard to case, so
operator `VECTOR, PG_TRGM` and application `['pg_trgm', 'btree_gin']` produce
`vector,pg_trgm,btree_gin`. An explicit empty operator value clears the list,
even when the application requests extensions. With no application extensions,
the Recipe sends the operator value unchanged. With no operator entry, an
omitted or empty application list sends no update and preserves any existing
allow-list.

The `tls` property maps to `require_secure_transport`: `required` (the default)
maps to `ON`, and `optional` maps to `OFF`. An operator entry overrides this
mapping, even if it conflicts with the application request. The connection
property reports the application's request, not the effective server setting.
An operator-pinned `OFF` permits plaintext connections; TLS remains available.
Keep TLS required with the Azure pack as written because its server is publicly
reachable. See the pack's [transport warning](../../../../recipe-packs/azure-aks/README.md#postgresql-transport-policy).

## Outputs and publication

The result contains the AVM's actual server ID and, when used, the SQL
deployment-script ID for cleanup, plus `host`, `port`, and `database`
connection values. Keep `bicep/bicepconfig.json`
beside the source when building or publishing. It enables ARM 2.0 symbolic
references so outputs reference the actual AVM deployment, rather than
looking for the Radius nested deployment in the Azure resource group.

## SQL initialization

Nonempty `initSql` runs after the AVM deployment completes, including its
database and server configuration. The runner uses the AVM's actual
hostname. It passes the password and SQL through secure environment
variables, requires TLS even when the application requests optional TLS,
and sends SQL to `psql` through standard input without shell evaluation.
It ignores local `psql` startup files and stops on the first SQL error.
Results and database errors are suppressed because they can contain SQL
or credentials. Failures report a fixed error and fail the Recipe.

The Azure CLI 2.77.0 deployment-script image uses Azure Linux. The runner
installs the PostgreSQL client only if it is absent. It loads only the
official base package repository to reduce memory use and keeps package
signature checks enabled. Client installation failure stops initialization.
The script has a 15-minute timeout, including installation and SQL
execution; each connection attempt has a 15-second timeout.

The identity that deploys the Recipe needs permission to manage
`Microsoft.Resources/deploymentScripts`, plus the temporary Azure
Container Instance and storage account used by the deployment-script
service. No script identity or Azure login is needed to run password-based
SQL. See [deployment-script permissions](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-script-bicep#configure-the-minimum-permissions).
Azure's `cleanupPreference: Always` requests removal of the temporary
container and storage account on success or failure. The deployment-script
resource has a one-day retention period and is also returned to Radius
for application cleanup. Full live cleanup verification remains in
[#472](https://github.com/radius-project/resource-types-contrib/issues/472).

The stock Recipe uses a publicly reachable server and firewall rule.
The runner must resolve and reach that endpoint and download client
packages. This implementation does not add private-network runner support.
If you change network policy, provide a compatible runner path separately.

SQL changes update the runner's execution tag. A later deployment can also
run the script again after retention expires. There is no exactly-once
guarantee, automatic undo, or implicit whole-script transaction. See
[database initialization](../../README.md#database-initialization) for an
example that is safe to repeat.

## Publishing and local checks

**Release prerequisite:** The pack references
`ghcr.io/radius-project/azure-aks-recipes/postgresqldatabases:latest`.
The publishing workflow includes this Recipe, but public availability of
that new image is not verified. Publish and verify the required version
through the normal release process, including anonymous pull access,
before releasing or deploying a pack that uses it. Do not treat a source
merge or an `edge` publication as proof that `latest` is ready.

Run `make test-postgresql-settings` for compiled-contract checks, Azure
snapshots, and SQL-runner shell fixtures without a deployment. Live
deployment checks and cleanup verification are tracked in
[#472](https://github.com/radius-project/resource-types-contrib/issues/472).
