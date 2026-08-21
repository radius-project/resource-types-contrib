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
| `tls` | string (`required`, `optional`) | Optional | The requested transport policy for connections to the database server. Defaults to `required`. The Azure Recipe enforces it on the server, which then rejects connections that do not use TLS; set `optional` to have the server also accept connections that do not use TLS. |
| `host` | string | Read only | The host name used to connect to the database. Set from the Recipe module's output. |
| `port` | integer | Optional | The TCP port used to connect to the database. Defaults to `3306`, the standard port every Recipe in this repository provisions. A Recipe that provisions the database on a different port overwrites this value from its own output. Setting it in an application definition changes only the value reported to connected containers, never the port the server listens on. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/mySqlDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure/aks-recipepack.bicep`](../../recipe-packs/azure/aks-recipepack.bicep) | Direct module — Azure Verified Module `avm/res/db-for-my-sql/flexible-server` |
| Kubernetes | [`recipe-packs/kubernetes/default-recipepack.bicep`](../../recipe-packs/kubernetes/default-recipepack.bicep) | `ghcr.io/radius-project/kube-recipes/mysqldatabases` |

This repository also contains an AWS Terraform Recipe under [`recipes/aws/terraform`](recipes/aws/terraform), which is not yet part of a Recipe Pack.

Only the Azure Recipe enforces the `tls` property, which it maps onto the flexible server's `require_secure_transport` parameter. The Kubernetes and AWS Recipes do not enforce it today, so on those platforms the value states the requested transport policy rather than observed server behavior.

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
