# Azure PostgreSQL Recipe

This Recipe wraps Azure Verified Module
`avm/res/db-for-postgre-sql/flexible-server:0.15.2`. It keeps the Azure AKS
pack's server name, version, sizes, storage, authentication, and network defaults.

The Recipe accepts the Radius `context`, an optional stable Azure `name`, and an optional
operator `configurations` array in AVM `{ name, source, value }` form.
It maps application `extensions`, `serverSettings`, and `tls` to server
configuration. Operator entries take precedence. The pack supplies the existing
server name; standalone Recipes derive one from the Radius resource ID.
It returns the server ID and,
when used, the initialization deployment-script ID for cleanup, plus `host`,
`port`, and `database` connection values.

Nonempty `initSql` runs through an Azure deployment script after the AVM
deployment completes. The runner installs the PostgreSQL client in the Azure CLI
2.77.0 Azure Linux image. Credentials and SQL use secure environment variables.
Client installation uses only the official base package repository to reduce
memory use in the runner. Package signature checks remain enabled.
The checked-in `bicep/bicepconfig.json` enables ARM 2.0 symbolic references for
this Recipe only. Keep it beside the Bicep source when building or publishing.
This lets the runner read the AVM's actual hostname after the module completes,
without looking for the Radius nested deployment in the Azure scope.
The runner uses TLS, fails on SQL errors, and does not print SQL output.
The script has a 15-minute timeout. Azure cleans up its temporary container and
storage account on success or failure.

See the [resource documentation](../../README.md#database-initialization) for
rerun rules, permissions, network limits, and safe SQL patterns.
