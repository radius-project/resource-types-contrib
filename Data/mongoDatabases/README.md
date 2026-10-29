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

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/mongoDatabases` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure-aks/azure-aks.bicep`](../../recipe-packs/azure-aks/azure-aks.bicep) | Direct module — Azure Verified Module `avm/res/document-db/database-account` |

### Kubernetes Recipe

The Kubernetes Recipe ([`recipes/kubernetes/terraform`](recipes/kubernetes/terraform)) runs a single MongoDB server from the official `mongo` image in the Environment's namespace, with authentication enabled. It is meant for development and testing:

- The server is MongoDB 7.0. MongoDB 8.0 and later refuse to start on Linux kernel 6.19 and newer ([SERVER-121912](https://jira.mongodb.org/browse/SERVER-121912)). 7.0 does not have that restriction.
- Clients connect on port `27017`. There is no TLS.
- The Recipe generates a password for an administrator named `admin` with `random_password` and keeps both in a Kubernetes `Secret`. The image creates the administrator in the `admin` database when the server first starts. The password is kept in the Terraform state, so it stays the same when the Recipe runs again.
- Storage is an `emptyDir` volume, so data is lost when the Pod is replaced.
- MongoDB creates the database named by `database` on the first write. The Recipe does not create it in advance.

| Output | Value |
| --- | --- |
| `endpoint` | The DNS name and port of the MongoDB `Service`, `<resource-name>.<namespace>.svc.cluster.local:27017`. |
| `database` | The database name from `database`, `mongo_db` by default. |
| `secrets.connectionString` | `mongodb://admin:<password>@<endpoint>/<database>?authSource=admin`. Delivered through the managed secret. |

The checked-in Kubernetes Recipe Pack, [`recipe-packs/kubernetes/default.bicep`](../../recipe-packs/kubernetes/default.bicep), registers only Bicep Recipes published to GHCR, so it does not reference this Terraform module. To use the module, add a `Radius.Data/mongoDatabases` entry with `kind: 'terraform'` to a Recipe Pack and set its `source` to the location where you host the module, as the repository's CI does when it tests Terraform Recipes.

## Using the resource type

Add a `mongoDatabases` resource to your application and connect a container to it. With Radius control-plane support from `radius-project/radius#12709` and Kubernetes Container Recipe support from `resource-types-contrib#300` or later, one connection named `mongodb` injects ordinary `CONNECTION_MONGODB_DATABASE` and `CONNECTION_MONGODB_ENDPOINT` values plus the secret-backed `CONNECTION_MONGODB_CONNECTIONSTRING`. No second managed-Secret connection is needed on compatible Kubernetes versions. For custom or backward-compatible Kubernetes configuration, `mongo.properties.secrets.name` remains available as the `secretName` for an explicitly authored `secretKeyRef`. See [`test/app.bicep`](test/app.bicep) for the gradual-adoption example.
