# Azure PostgreSQL Recipe

This Recipe converts the application's `serverSettings` map and `extensions`
list to the `configurations` array that Azure Verified Module
`avm/res/db-for-postgre-sql/flexible-server:0.15.2` accepts. Direct-module
mapping cannot perform this conversion and merge operator overrides. The
Recipe still uses the same pinned AVM to provision the server. It retains
the Azure AKS pack's server name, version, sizes, storage, authentication,
and network defaults.

The inputs are the Radius `context`, an optional stable Azure `name`, and
an optional operator `configurations` array in AVM `{ name, source, value }`
form. The pack supplies its existing hash-based server name. A standalone
Recipe derives a name from the Radius resource ID.

Operator entries take precedence over matching application settings.
Comparisons ignore name case, as required by the
[Azure resource naming rules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules).
Other setting names and values are forwarded unchanged. Use canonical
lowercase names in configuration.

The application must use `extensions` for `azure.extensions` and `tls`
for `require_secure_transport`; generic `serverSettings` cannot override
these properties. An omitted or empty extension list sends no allow-list
update. An operator can replace the list, or clear it with an explicit
empty `azure.extensions` value. All `port` entries are ignored; Azure
PostgreSQL stays on port 5432.

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
