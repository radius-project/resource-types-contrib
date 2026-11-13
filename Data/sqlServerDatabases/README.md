# Radius.Data/sqlServerDatabases

## Overview

The **Radius.Data/sqlServerDatabases** resource type represents a SQL Server database. It allows developers to create and easily connect to a SQL Server database as part of their Radius applications. The developer provides the administrator `username` and `password` directly on the resource; the `password` property is marked `x-radius-sensitive`, so Radius encrypts it at rest, redacts it on reads, and injects it decrypted only into the platform's Recipe.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.Data/sqlServerDatabases` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `database` | string | Required | The SQL database name to create on the server. Defaults to `appdb`. |
| `username` | string | Required | The administrator username for the SQL database. Passed to the Recipe as `{{context.resource.properties.username}}`. |
| `password` | string (`x-radius-sensitive`) | Required | The administrator password. Encrypted at rest, redacted on reads, and injected decrypted into the Recipe as `{{context.resource.properties.password}}`. |
| `host` | string | Read only | The SQL Server fully qualified domain name. Set from the Recipe module's output. |
| `port` | integer | Optional | The TCP port used to connect to the database. Defaults to `1433`, the standard port every Recipe in this repository provisions. A Recipe that provisions the database on a different port overwrites this value from its own output. Setting it in an application definition changes only the value reported to connected containers, never the port the server listens on. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/sqlServerDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure-aks/azure-aks.bicep`](../../recipe-packs/azure-aks/azure-aks.bicep) | Direct module — Azure Verified Module `mcr.microsoft.com/bicep/avm/res/sql/server:0.21.4` |
| Kubernetes | Register either Recipe in an Environment Recipe Pack | [Bicep](recipes/kubernetes/bicep/kubernetes-sqlserver.bicep) or [Terraform](recipes/kubernetes/terraform/main.tf) |

## Kubernetes Recipe

These Recipes run SQL Server 2022 CU28 **Developer edition**, for development
and test only. They are not a production or high-availability database service.
The operator must read and accept the [Microsoft SQL Server license
terms](https://go.microsoft.com/fwlink/?linkid=857698) before setting the required
Recipe parameter `sqlServerAcceptEula` to `Y`. Neither Recipe supplies consent
by default. Do not configure this Recipe as an unattended default without that
operator decision.

Both Recipes require Linux **amd64** nodes (not ARM or emulation), two available
CPUs, at least 3 GiB of available container memory, and a default StorageClass
with ReadWriteOnce storage that supports UID/GID 10001 through `fsGroup`.
The container requests 2 GiB and limits memory to 3 GiB; SQL Server's memory
target is 2048 MB. `sqlServerStorageSize` defaults to `8Gi`. Set a larger value
before the first deployment when needed. The namespace comes from the Radius
context; the Recipe does not create or change it.

The Recipes create a PVC, a Secret, a single-replica Deployment with `Recreate`
updates, and an internal ClusterIP Service. SQL Server creates the requested
non-system `database` and the supplied SQL login. A non-`sa` login receives
`sysadmin`, consistent with the resource's administrator contract; do not use
this login for an untrusted application. Both `sa` and that login use the
supplied password, which must meet SQL Server password policy. Login and database
names must contain 1 to 128 UTF-16 code units. SQL identifiers and string
literals are escaped; sqlcmd variable substitution is disabled.

Readiness requires a successful query against the requested database as the
requested login, not just an open socket. Connections use port **1433**;
an input `port` does not change it. SQL Server uses its generated certificate.
The local probe trusts that certificate (`sqlcmd -C`); applications must configure
their own TLS trust. This Recipe does not supply a public CA certificate.

Data survives Pod replacement. Keep the same database, username and password
when redeploying an existing PVC. Changing resource properties is not a supported
credential-rotation or database-rename procedure: SQL Server retains the original
`sa` password in its system database. Use an operator-managed SQL maintenance
procedure for such changes. A Secret update does not restart the Pod.
All four objects, including the PVC, are listed in `result.resources`.
**Deleting the Radius resource deletes the PVC and can delete all database data**,
subject to the StorageClass reclaim policy. Back up data outside this PVC.

`result.values` contains `host` (`<name>.<namespace>.svc.cluster.local`), `port`
(`1433`) and `database`. The user supplies credentials through the sensitive
resource input, so the Recipes do not return a second copy in `result.secrets`.
Kubernetes stores the password in a Secret, not a command argument or ConfigMap.
Enable Kubernetes Secret encryption and restrict RBAC. Terraform state also
contains the Secret: use an encrypted state store with restricted access.

For either Recipe, set these Environment Recipe Pack parameters:

```bicep
parameters: {
  // Only after the operator has accepted the license terms:
  sqlServerAcceptEula: 'Y'
  sqlServerStorageSize: '8Gi' // optional
}
```

The Bicep compiler embeds `terraform/bootstrap.sh` into the published module.
Keep that sibling directory when building from this repository.
The Terraform package is self-contained and must include `bootstrap.sh`.
The following checks require no cluster and start no SQL Server. They use mock
executables/provider plans and the Radius-bundled Bicep compiler. Set `BICEP_CLI`
if that compiler is not at `~/.rad/bin/bicep` (`bicep.exe` on Windows).

```bash
node --test .github/scripts/tests/test-sqlserver-kubernetes.js
shellcheck Data/sqlServerDatabases/recipes/kubernetes/terraform/bootstrap.sh
terraform -chdir=Data/sqlServerDatabases/recipes/kubernetes/terraform init -backend=false
terraform -chdir=Data/sqlServerDatabases/recipes/kubernetes/terraform validate
terraform -chdir=Data/sqlServerDatabases/recipes/kubernetes/terraform test
```

See the [testing guide](../../docs/contributing/testing-resource-types-recipes.md)
for local publishing and Recipe Pack registration. In a **dedicated** test
environment, register the Recipe with explicit license consent, then run:

```bash
make test-recipe RECIPE_PATH=Data/sqlServerDatabases/recipes/kubernetes/bicep
make test-recipe RECIPE_PATH=Data/sqlServerDatabases/recipes/kubernetes/terraform
```

The existing test app uses the non-`sa` login `radadmin` and database `appdb`.
Its demo container has no SQL Server backend. Deployment readiness checks the SQL
login and database; this app alone does not test application SQL queries or
data persistence. Do not run these deployment tests against a shared cluster.

## Using the resource type

Add a `sqlServerDatabases` resource to your application and connect a container to it. Radius injects the database's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_SQL_HOST`, `CONNECTION_SQL_PORT`, and `CONNECTION_SQL_DATABASE`). See [`test/app.bicep`](test/app.bicep) for a complete example.
