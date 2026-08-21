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
| `port` | string | Read only | The SQL Server TCP port. Azure SQL Database listens on 1433. |

## Naming constraints

`database` and `username` are used verbatim as cloud resource names, so from API version
`2026-09-01-preview` they carry format constraints. Radius validates them when the resource is
submitted, which means a bad value is rejected before a Recipe runs and before a billable
database server exists. API version `2025-08-01-preview` is unconstrained and unchanged.

| Property | Accepted format |
| --- | --- |
| `database` | 1-128 characters. The characters `< > * % & : \ / ?` and control characters are not allowed anywhere, and the name may not end with a period or a space. Periods and spaces are allowed inside the name. |
| `username` | 1-128 characters. Starts with a letter, followed by letters, digits or underscores. |

### Reserved names

Some names satisfy the format above but are still rejected by the provider. These cannot be
expressed as schema constraints today — Radius rejects the `not` and `oneOf` keywords, and the
pattern engine has no negative lookahead — so they are listed here instead.

| Name | Behaviour |
| --- | --- |
| `master`, `model`, `msdb`, `tempdb` | SQL Server system databases. Requesting them as `database` fails the deployment. |
| `sa`, `admin`, `administrator`, `guest`, `public`, `root` | Rejected by Azure SQL as administrator logins. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/sqlServerDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure/bicep-recipepack.bicep`](../../recipe-packs/azure/bicep-recipepack.bicep) | Direct module — Azure Verified Module `mcr.microsoft.com/bicep/avm/res/sql/server:0.21.4` |

## Using the resource type

Add a `sqlServerDatabases` resource to your application and connect a container to it. Radius injects the database's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_SQL_HOST`, `CONNECTION_SQL_PORT`, and `CONNECTION_SQL_DATABASE`). See [`test/app.bicep`](test/app.bicep) for a complete example.
