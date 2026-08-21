# Radius.Data/mongoDatabases

## Overview

The **Radius.Data/mongoDatabases** resource type represents a Mongo-compatible database. It allows developers to create and easily connect to a Mongo database as part of their Radius applications. The Azure Recipe Pack provisions Cosmos DB for MongoDB using the Azure Verified Module and exposes its endpoint and connection string as read-only resource properties.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.Data/mongoDatabases` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `database` | string | Optional | The Mongo database name. Defaults to `mongo_db`. |
| `endpoint` | string | Read only | The endpoint used to connect to the database. Set from the Recipe module's output. |
| `secrets` | object | Read only | Recipe secrets. `secrets.name` references the managed `Radius.Security/secrets` resource; `secrets.connectionString` is the secret key (delivered via that managed secret, never stored on the resource). |

## Naming constraints

`database` is used verbatim as a cloud resource name, so from API version `2026-09-01-preview` it
carries format constraints. Radius validates it when the resource is submitted, which means a bad
value is rejected before a Recipe runs and before a billable account exists. API version
`2025-08-01-preview` is unconstrained and unchanged.

| Property | Accepted format |
| --- | --- |
| `database` | 1-63 characters. May not contain spaces, control characters, or any of `/ \ . " $ * < > : \| ? #`. |

Azure does not publish a naming contract for the Cosmos DB Mongo child database, so this is a
deliberately conservative subset: the intersection of the MongoDB database-name rules across
operating systems with the characters Azure disallows in a resource ID. Some names it rejects may
in fact be accepted by a given backend.

### Reserved names

Some names satisfy the format above but are still rejected by the engine. These cannot be
expressed as schema constraints today — Radius rejects the `not` and `oneOf` keywords, and the
pattern engine has no negative lookahead — so they are listed here instead.

| Name | Behaviour |
| --- | --- |
| `admin`, `local`, `config` | MongoDB internal databases. Using them as an application database fails or behaves unexpectedly. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/mongoDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure/bicep-recipepack.bicep`](../../recipe-packs/azure/bicep-recipepack.bicep) | Direct module — Azure Verified Module `avm/res/document-db/database-account` |

## Using the resource type

Add a `mongoDatabases` resource to your application and connect a container to it. Radius injects the database's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_MONGODB_DATABASE` and `CONNECTION_MONGODB_ENDPOINT`). The `connectionString` secret is not injected — bind it from the managed `Radius.Security/secrets` resource with a container `secretKeyRef` using `mongo.properties.secrets.name`. See [`test/app.bicep`](test/app.bicep) for a complete example.
