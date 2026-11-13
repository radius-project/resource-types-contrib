# Radius.Data/mySqlDatabases

## Overview

The **Radius.Data/mySqlDatabases** resource type represents a MySQL database. It allows developers to create and easily connect to a MySQL database as part of their Radius applications. The developer provides the administrator `username` and `password` directly on the resource; the `password` property is marked `x-radius-sensitive`, so Radius encrypts it at rest, redacts it on reads, and injects it decrypted only into the platform's Recipe.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.Data/mySqlDatabases` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `username` | string | Required | The administrator username for the MySQL database. Passed to the Recipe as `{{context.resource.properties.username}}`. |
| `password` | string (`x-radius-sensitive`) | Required | The administrator password. Encrypted at rest, redacted on reads, and injected decrypted into the Recipe as `{{context.resource.properties.password}}`. |
| `database` | string | Optional | The name of the database. Defaults to `mysql_db`. |
| `version` | string (`5.7`, `8.0`, `8.4`) | Optional | The major MySQL server version. Defaults to `8.4`. |
| `tls` | string (`required`, `optional`) | Optional | The requested transport policy for connections to the database server. Defaults to `required`. Use `optional`, which permits non-TLS connections, only when the server is not publicly reachable. See below for platform behavior. |
| `host` | string | Read only | The host name used to connect to the database. Set from the Recipe module's output. |
| `port` | integer | Optional | The TCP port used to connect to the database. Defaults to `3306`, the standard port every Recipe in this repository provisions. A Recipe that provisions the database on a different port overwrites this value from its own output. Setting it in an application definition changes only the value reported to connected containers, never the port the server listens on. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/mySqlDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure-aks/azure-aks.bicep`](../../recipe-packs/azure-aks/azure-aks.bicep) | Direct module — Azure Verified Module `avm/res/db-for-my-sql/flexible-server` |
| AWS | [`recipe-packs/aws-eks/aws-eks.bicep`](../../recipe-packs/aws-eks/aws-eks.bicep) | `ghcr.io/radius-project/aws-eks-recipes/mysqldatabases` (Amazon RDS for MySQL) |
| Kubernetes | [`recipe-packs/kubernetes/default.bicep`](../../recipe-packs/kubernetes/default.bicep) | `ghcr.io/radius-project/kube-recipes/mysqldatabases` |

## Using the resource type

Add a `mySqlDatabases` resource to your application and connect a container to
it. Unless `disableDefaultEnvVars` is enabled on the connection, Radius injects
the database's connection properties into the container as environment
variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>`. For example, a
connection named `mysqldb` produces `CONNECTION_MYSQLDB_HOST`,
`CONNECTION_MYSQLDB_PORT`, `CONNECTION_MYSQLDB_DATABASE`, and
`CONNECTION_MYSQLDB_TLS`. Because `tls` defaults to `required`, configure your
MySQL client for TLS — for example, by passing
`ssl: { minVersion: 'TLSv1.2' }` to the Node.js `mysql2` driver.

The Azure and AWS Recipes enforce the requested policy on the server. The
AWS Recipe's server is not publicly accessible; see
[Transport policy](../../recipe-packs/aws-eks/README.md#transport-policy) for
the certificate authority clients need to verify it. The Kubernetes
Recipes enforce `tls` through MySQL's `require_secure_transport` setting.
An omitted or `required` policy rejects plaintext TCP connections. `optional`
permits plaintext without disabling TLS. Both Recipes keep the MySQL image's
entrypoint, which creates server certificates. Encryption does not verify the
server's identity: clients need a trusted CA and hostname verification for that.

Use `optional` only when the server is not publicly reachable. Non-TLS
connections can expose administrator credentials and query traffic in transit.
Private reachability does not encrypt traffic, so TLS remains preferred.
Keep it required with the Azure pack as written; see
[MySQL transport policy](../../recipe-packs/azure-aks/README.md#mysql-transport-policy)
for public-network restrictions.

### Using developer-owned credentials

The Kubernetes Recipe no longer includes its unused developer-provided
`password` and derived `connectionString` entries in `result.secrets`. These
entries were not declared by the resource schema, so applications could not
consume them as managed outputs. Applications that need the password must
author the value in a `Radius.Security/secrets` resource.

With a Kubernetes Container Recipe that supports direct Secret connections,
connect the container to that authored Secret to receive secret-backed
`CONNECTION_<CONNECTION-NAME>_<KEY>` environment variables. For gradual
adoption or environments using an earlier Container Recipe, bind the authored
Secret explicitly with `env.valueFrom.secretKeyRef`, as shown in
[`test/app.bicep`](test/app.bicep). In either case, pass the same
developer-owned password to the database resource and the authored Secret; do
not depend on the MySQL Recipe to copy it into a new managed Secret.

## Kubernetes Recipes

The [Bicep Recipe](recipes/kubernetes/bicep/kubernetes-mysql.bicep) and
[Terraform Recipe](recipes/kubernetes/terraform/main.tf) create the same
Secret, Deployment, and ClusterIP Service in
`context.runtime.kubernetes.namespace`. They support MySQL `5.7`, `8.0`,
and `8.4` (default), and default the database name to `mysql_db`.
The server, Service, and reported connection use port `3306`, regardless of
an authored `port` property.

Both Recipes return three Kubernetes UCP IDs in `result.resources` for cleanup
and `host`, `port`, and `database` in `result.values`. Neither returns
`result.secrets`: the administrator credentials remain developer-owned inputs.
The Pod reads them from a Kubernetes Secret. Protect Terraform state because
the provider stores the Secret data there.

These are development Recipes. They do not configure persistent storage or
backups. Pod replacement can lose data. Applying the TLS change rolls the
Deployment and rejects plaintext clients when `tls` is omitted or `required`.
Configure clients for TLS before updating an existing deployment. MySQL `5.7`
is retained for compatibility; prefer a supported MySQL release.

The Bicep publication path remains
`ghcr.io/radius-project/kube-recipes/mysqldatabases`.
For Terraform, package `recipes/kubernetes/terraform` as a module archive or
reference that directory from a Git source pinned to a commit. For local,
dedicated test clusters, `make build-terraform-recipe` publishes the archive
`mySqlDatabases-kubernetes.zip` to the test module server. Adding source files
does not publish the module or change an Environment's Recipe Pack.

### Offline validation

Use the Radius-bundled Bicep CLI, Node.js, and Terraform 1.7+ (mock providers
require 1.7). From the repository root:

```bash
node --test Data/mySqlDatabases/test/kubernetes-recipe.test.js
terraform -chdir=Data/mySqlDatabases/recipes/kubernetes/terraform init -backend=false -input=false
terraform -chdir=Data/mySqlDatabases/recipes/kubernetes/terraform fmt -check -recursive
terraform -chdir=Data/mySqlDatabases/recipes/kubernetes/terraform validate
terraform -chdir=Data/mySqlDatabases/recipes/kubernetes/terraform test
```

These tests evaluate Bicep snapshots and mocked Terraform plans. They check
defaults, explicit and null properties, TLS arguments, Secret references,
namespace selection, selectors, actual ports, and cleanup/output contracts.
Terraform also checks invalid version and TLS inputs.
They do not prove live TLS behavior or deploy to a cluster.

For each recipe kind, use the build, Recipe Pack, and `make test-recipe` steps
in the [testing guide](../../docs/contributing/testing-resource-types-recipes.md)
on a dedicated cluster. Publish Bicep with `rad bicep publish`, not
`az bicep build`, so validation uses the Radius-bundled compiler.
