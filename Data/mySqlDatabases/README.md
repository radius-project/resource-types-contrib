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
| `host` | string | Read only | The host name used to connect to the database. Set from the Recipe module's output. |
| `port` | integer | Read only | The port number used to connect to the database. Set from the Recipe module's output. |
| `sslMode` | string (`required`, `disabled`) | Read only | The transport the provisioned database requires. Set by the Recipe. The Azure Recipe sets `required`, because Azure Database for MySQL flexible server runs with `require_secure_transport` `ON`; the Kubernetes and AWS Recipes set `disabled`. Read this value rather than assuming a transport. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/mySqlDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure/aks-recipepack.bicep`](../../recipe-packs/azure/aks-recipepack.bicep) | Azure Database for MySQL flexible server [`recipes/azure`](recipes/azure) |

## Using the resource type

Add a `mySqlDatabases` resource to your application and connect a container to it. Radius injects the database's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_MYSQLDB_HOST`, `CONNECTION_MYSQLDB_PORT`, `CONNECTION_MYSQLDB_DATABASE`, and `CONNECTION_MYSQLDB_SSLMODE`). See [`test/app.bicep`](test/app.bicep) for a complete example.

### Connecting over TLS

The same application definition can be deployed to any platform that offers a Recipe for this type, but the provisioned servers do not all accept the same transport. Rather than hard-coding a transport, read `sslMode` and configure the client from it. For a `mysql2` pool:

```js
const pool = mysql.createPool({
  host: process.env.CONNECTION_MYSQLDB_HOST,
  user,
  password,
  database: process.env.CONNECTION_MYSQLDB_DATABASE,
  ssl: process.env.CONNECTION_MYSQLDB_SSLMODE === 'required' ? { minVersion: 'TLSv1.2' } : undefined,
});
```

A client that always negotiates TLS also works against every Recipe in this repository, since the Kubernetes and AWS servers accept TLS even though they do not require it.

