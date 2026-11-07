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

The result contains the AVM's actual server ID for cleanup and its `host`,
`port`, and `database` connection values. Keep `bicep/bicepconfig.json`
beside the source when building or publishing. It enables ARM 2.0 symbolic
references so outputs reference the actual AVM deployment, rather than
looking for the Radius nested deployment in the Azure resource group.

**Release prerequisite:** The pack references
`ghcr.io/radius-project/azure-aks-recipes/postgresqldatabases:latest`.
The publishing workflow includes this Recipe, but public availability of
that new image is not verified. Publish and verify the required version
through the normal release process, including anonymous pull access,
before releasing or deploying a pack that uses it. Do not treat a source
merge or an `edge` publication as proof that `latest` is ready.

Run `make test-postgresql-settings` for compiled-contract checks and Azure
snapshots without a deployment. Live deployment checks and cleanup
verification are tracked in [#472](https://github.com/radius-project/resource-types-contrib/issues/472).
