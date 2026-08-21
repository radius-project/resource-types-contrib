# Radius.Data/postgreSqlDatabases

## Overview

The **Radius.Data/postgreSqlDatabases** resource type represents a PostgreSQL database. It allows developers to create and easily connect to a PostgreSQL database as part of their Radius applications. The developer provides the administrator `username` and `password` directly on the resource; the `password` property is marked `x-radius-sensitive`, so Radius encrypts it at rest, redacts it on reads, and injects it decrypted only into the platform's Recipe.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.Data/postgreSqlDatabases` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `username` | string | Required | The administrator username for the PostgreSQL database. Passed to the Recipe as `{{context.resource.properties.username}}`. |
| `password` | string (`x-radius-sensitive`) | Required | The administrator password. Encrypted at rest, redacted on reads, and injected decrypted into the Recipe as `{{context.resource.properties.password}}`. |
| `database` | string | Optional | The name of the database. Defaults to `postgres_db`. |
| `size` | string (`S`, `M`, `L`) | Optional | The size of the PostgreSQL database. Defaults to `S`. The Recipe maps the size onto a concrete cloud SKU/tier. |
| `initSql` | string | Optional | Optional SQL script executed on first initialization to create tables, indexes, and seed data. |
| `host` | string | Read only | The host name used to connect to the database. Set from the Recipe module's output. |
| `port` | integer | Read only | The port number used to connect to the database. Set from the Recipe module's output. |

## Naming constraints

`database` and `username` are used verbatim as cloud resource names, so from API version
`2026-09-01-preview` they carry format constraints. Radius validates them when the resource is
submitted, which means a bad value is rejected before a Recipe runs and before a billable
database server exists. API version `2025-08-01-preview` is unconstrained and unchanged.

| Property | Accepted format |
| --- | --- |
| `database` | 1-63 characters. Starts with a letter or an underscore, followed by letters, digits or underscores. |
| `username` | 1-63 letters and digits. Azure PostgreSQL Flexible Server rejects every other character, including hyphens and underscores. |

### Reserved names

Some names satisfy the format above but are still rejected, or are unsafe to use, because the
provider or the engine has already claimed them. These cannot be expressed as schema constraints
today — Radius rejects the `not` and `oneOf` keywords, and the pattern engine has no negative
lookahead — so they are listed here instead.

| Name | Behaviour |
| --- | --- |
| `postgres` | Created automatically on every server. The Azure Recipe binds your application to the existing database instead of trying to create it again, so this value works. |
| `azure_maintenance`, `azure_sys` | Created automatically by Azure for internal use. Requesting them fails the deployment. |
| `template0`, `template1` | PostgreSQL template databases. `template0` refuses connections. Requesting them fails the deployment. |
| Usernames starting with `pg_` | Reserved by PostgreSQL for system roles. Already excluded by the `username` format, which allows no underscores. |
| `azure_superuser`, `azure_pg_admin` | Reserved by Azure. Already excluded by the `username` format. |
| `admin`, `administrator`, `root`, `guest`, `public` | Rejected by Azure as administrator logins. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/postgreSqlDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure/aks-recipepack.bicep`](../../recipe-packs/azure/aks-recipepack.bicep) | [`recipes/azure/bicep/azure-postgresql.bicep`](recipes/azure/bicep/azure-postgresql.bicep), which wraps the Azure Verified Module `avm/res/db-for-postgre-sql/flexible-server` |

## Using the resource type

Add a `postgreSqlDatabases` resource to your application and connect a container to it. Radius injects the database's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_POSTGRES_HOST`, `CONNECTION_POSTGRES_PORT`, and `CONNECTION_POSTGRES_DATABASE`). See [`test/app.bicep`](test/app.bicep) for a complete example.
