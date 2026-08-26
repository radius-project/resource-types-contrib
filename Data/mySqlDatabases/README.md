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
| `tls` | string (`required`, `optional`) | Optional | The transport policy for connections to the database server. Defaults to `required`, which makes the server reject unencrypted network connections; set `optional` to have the server also accept them. Enforced by every Recipe — see [Transport policy](#transport-policy). |
| `host` | string | Read only | The host name used to connect to the database. Set from the Recipe module's output. |
| `port` | integer | Optional | The TCP port used to connect to the database. Defaults to `3306`, the standard port every Recipe in this repository provisions. A Recipe that provisions the database on a different port overwrites this value from its own output. Setting it in an application definition changes only the value reported to connected containers, never the port the server listens on. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/mySqlDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure/aks-recipepack.bicep`](../../recipe-packs/azure/aks-recipepack.bicep) | Direct module — Azure Verified Module `avm/res/db-for-my-sql/flexible-server` |
| Kubernetes | [`recipe-packs/kubernetes/default-recipepack.bicep`](../../recipe-packs/kubernetes/default-recipepack.bicep) | `ghcr.io/radius-project/kube-recipes/mysqldatabases` |

This repository also contains an AWS Terraform Recipe under [`recipes/aws/terraform`](recipes/aws/terraform), which is not yet part of a Recipe Pack.

## Transport policy

Every Recipe enforces the `tls` property on the server it provisions, each by way of the MySQL `require_secure_transport` system variable, so the property describes observed server behavior rather than intent:

| Platform | How the Recipe enforces it |
| --- | --- |
| Azure | Sets the flexible server's `require_secure_transport` configuration. |
| AWS | Sets `require_secure_transport` in the RDS DB parameter group. The parameter is dynamic, so it applies without a reboot. |
| Kubernetes | Passes `--require-secure-transport` to `mysqld` as a container argument. |

With `tls: 'required'` the server rejects unencrypted network connections, returning `MySQL Error 3159 (HY000)`. Connections over the local Unix socket are exempt, which is how the Kubernetes Recipe's container still initializes its database and user on first start. With `tls: 'optional'` the server continues to accept TLS connections but no longer requires them over the network.

> [!NOTE]
> `tls: 'optional'` is not the same as "plaintext works with no client changes". For accounts that use the `caching_sha2_password` authentication plugin — which is the default in MySQL 8.x, and therefore what the Kubernetes Recipe's generated user gets — the server still refuses to accept credentials over an unencrypted connection unless the client performs an RSA key exchange. Such a client also needs `--get-server-public-key` (mysql CLI) or the driver equivalent.

### How a client trusts the server certificate

The three platforms differ in what the client can verify, so a client configuration that is safe on one platform is not automatically as safe on another. In every case the client needs the right CA material; TLS verification is not automatic:

| Platform | Certificate | What the client can verify |
| --- | --- | --- |
| Azure | Issued by an Azure-managed CA chain (see [Azure Database for MySQL root certificates](https://learn.microsoft.com/azure/mysql/flexible-server/concepts-networking-ssl-tls)) | Encryption, CA verification, and hostname verification, given the current root certificates |
| AWS | Issued by an Amazon RDS CA | Encryption, CA verification, and hostname verification, once the client installs the [RDS CA bundle](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html) (`--ssl-ca=global-bundle.pem`) |
| Kubernetes | Self-signed, generated by the server on first start | **Encryption only** |

Configure the client for the platform it runs against:

```js
import { readFileSync } from 'node:fs'

// Azure — supply a bundle containing the current Azure root certificates
mysql.createPool({ host, user, password, database, ssl: { ca: readFileSync('combined-ca-certificates.pem') } })

// AWS — supply the RDS CA bundle
mysql.createPool({ host, user, password, database, ssl: { ca: readFileSync('global-bundle.pem') } })

// Kubernetes — encrypt without verifying the server
mysql.createPool({ host, user, password, database, ssl: { rejectUnauthorized: false } })
```

On Azure, use a bundle containing every root the server may chain to rather than a single certificate. The service rotates roots, and the current set spans both DigiCert Global Root G2 and Microsoft RSA Root CA 2017, so pinning one of them can start failing after a rotation.

On Kubernetes the MySQL server generates its own CA and certificate inside its data directory, and the Recipe does not expose or distribute that CA, so clients cannot authenticate the server under the current contract. Use `--ssl-mode=REQUIRED` (mysql CLI) or `ssl: { rejectUnauthorized: false }`, which encrypts the connection **without authenticating the server**. Traffic is protected from passive observation, but an attacker able to intercept traffic inside the cluster could still impersonate the database. Treat the Kubernetes Recipe as a development and testing configuration, and use a Recipe that supplies a trusted certificate where server authentication matters.

> [!NOTE]
> The `mysql:5.7` image is published for `amd64` only. On `arm64` Kubernetes nodes, choose `version: '8.0'` or `version: '8.4'`.
>
> The Kubernetes Recipe Pack pins `ghcr.io/radius-project/kube-recipes/mysqldatabases:latest`, which tracks stable releases. Environments using the published pack pick up this enforcement at the next stable Recipe release; the `:edge` tag carries it as soon as the change merges.

## Using the resource type

Add a `mySqlDatabases` resource to your application and connect a container to
it. Unless `disableDefaultEnvVars` is enabled on the connection, Radius injects
the database's connection properties into the container as environment
variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>`. For example, a
connection named `mysqldb` produces `CONNECTION_MYSQLDB_HOST`,
`CONNECTION_MYSQLDB_PORT`, `CONNECTION_MYSQLDB_DATABASE`, and
`CONNECTION_MYSQLDB_TLS`. Because `tls` defaults to `required`, configure your
MySQL client for TLS as shown in [Transport policy](#transport-policy). See
[`test/app.bicep`](test/app.bicep) for an example of declaring the resource and
wiring a connection to it.

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
