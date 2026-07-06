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
| `connectionString` | string | Read only | The connection string used to connect to the database. Set from the Recipe module's output. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipepack/`](../../recipepack). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/mongoDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipepack/azure/bicep-recipepack.bicep`](../../recipepack/azure/bicep-recipepack.bicep) | Direct module — Azure Verified Module `avm/res/document-db/database-account` |

## Using the resource type

Add a `mongoDatabases` resource to your application and connect a container to it. Radius injects the database's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_MONGODB_DATABASE`, `CONNECTION_MONGODB_ENDPOINT`, and `CONNECTION_MONGODB_CONNECTIONSTRING`). See [`test/app.bicep`](test/app.bicep) for a complete example.
