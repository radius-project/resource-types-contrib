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

## Naming constraints

`database` and `username` are used verbatim as cloud resource names, so from API version
`2026-09-01-preview` they carry format constraints. Radius validates them when the resource is
submitted, which means a bad value is rejected before a Recipe runs and before a billable
database server exists. API version `2025-08-01-preview` is unconstrained and unchanged.

| Property | Accepted format |
| --- | --- |
| `database` | 1-63 characters. Starts with a letter, followed by letters, digits or underscores. Azure caps the child database name at 63 even though MySQL itself allows 64. |
| `username` | 1-16 characters. Starts with a letter, followed by letters, digits or underscores. |

The 16 character username limit comes from AWS RDS, not Azure, which allows 32. Because this
resource type ships both an Azure and an AWS Recipe and the schema is shared, the constraint is
the stricter of the two so that the same application definition deploys on either platform.

### Reserved names

Some names satisfy the format above but are still rejected by the provider. These cannot be
expressed as schema constraints today — Radius rejects the `not` and `oneOf` keywords, and the
pattern engine has no negative lookahead — so they are listed here instead.

| Name | Behaviour |
| --- | --- |
| `mysql`, `information_schema`, `performance_schema`, `sys` | MySQL system databases. Requesting them as `database` fails the deployment. |
| `azure_superuser`, `admin`, `administrator`, `root`, `guest`, `sa`, `public` | Rejected by Azure as administrator logins. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/mySqlDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure/bicep-recipepack.bicep`](../../recipe-packs/azure/bicep-recipepack.bicep) | Direct module — Azure Verified Module `avm/res/db-for-my-sql/flexible-server` |

## Using the resource type

Add a `mySqlDatabases` resource to your application and connect a container to it. Radius injects the database's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_MYSQLDB_HOST`, `CONNECTION_MYSQLDB_PORT`, and `CONNECTION_MYSQLDB_DATABASE`). See [`test/app.bicep`](test/app.bicep) for a complete example.
