# Radius.Data/mongoDatabases

## Overview

The **Radius.Data/mongoDatabases** resource type represents a Mongo-compatible database. It allows developers to create and easily connect to a Mongo database as part of their Radius applications. The Azure Recipe Pack provisions Cosmos DB for MongoDB using the Azure Verified Module and exposes its endpoint and connection string as read-only resource properties. The Kubernetes recipes run a persistent MongoDB instance for development.

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
| Kubernetes | Register the authored Recipe in an Environment or Recipe Pack | [Bicep](recipes/kubernetes/bicep/kubernetes-mongodb.bicep) or [Terraform](recipes/kubernetes/terraform/main.tf) |

## Kubernetes recipes

Both recipes run one `mongo:8.0` instance behind a ClusterIP Service on port
27017. A 1 GiB ReadWriteOnce PVC stores `/data/db`. The cluster must have a
default StorageClass. Every object uses `context.runtime.kubernetes.namespace`.
The Deployment uses `Recreate` so an update cannot start two database processes
against the volume. Startup and readiness probes authenticate before they report
success.

These are development recipes, not a production database service. They do not
configure TLS, replication, backups, or network policy. The generated connection
uses the `radius` administrator account. Use a managed database or a hardened
operator deployment for production.

### Credentials and redeployment

The Bicep recipe requires a secure `mongoPassword` recipe parameter with at least
16 characters. Generate a strong password once, store it in your secret store,
and supply the same value on every deployment. For example, `openssl rand -hex 32`
generates a suitable value; do not put that value in source control or logs.
Pass it through a secure application deployment parameter:

```bicep
@secure()
param mongoPassword string

// In the Radius.Data/mongoDatabases resource's properties:
// recipe: {
//   parameters: {
//     mongoPassword: mongoPassword
//   }
// }
```

The required input is intentional. Bicep's `newGuid()` parameter default is
evaluated again for a new recipe deployment. It does not retain the password
used to initialize a persistent database.

Terraform accepts the same `mongoPassword` parameter. When it is omitted,
Terraform generates a 32-character random password and retains it in recipe
state. Keep that state protected and available for redeployments. Credentials
are stored in a Kubernetes Secret and referenced with `secretKeyRef`, not copied
into the Pod spec. The Terraform `result` output is sensitive.

MongoDB initializes the administrator only when `/data/db` is empty. Changing the
recipe password does **not** change an existing database password. Reuse the
original value. For rotation, first change the database password with an
authenticated MongoDB client, update the recipe parameter, and restart the
Deployment. Do not remove Terraform state or switch recipe implementations while
retaining the volume.

### Output and cleanup contract

Both recipes return the same output shape:

| Output | Value |
| --- | --- |
| `result.values.database` | `properties.database`, or `mongo_db` when omitted |
| `result.values.endpoint` | `mongodb://<service>.<namespace>.svc.cluster.local:27017` without credentials |
| `result.secrets.connectionString` | Authenticated URI with an encoded password and database path, and `authSource=admin` |
| `result.resources` | UCP IDs of the Secret, PVC, Deployment, and Service |

The database is created on the first write. Radius places `connectionString` in
the managed secret described above. No password is returned in `values`.
Deleting the Radius resource deletes all four recipe objects, including the PVC.
Data can be lost; the StorageClass reclaim policy controls deletion of the
underlying volume. Back up data before deleting the resource.

### Build and test

Run these checks without a cluster. Terraform 1.7 or later is required for the
mock-provider tests; the module itself supports Terraform 1.5 or later.

```bash
node --test Data/mongoDatabases/test/kubernetes-recipes.test.js
terraform -chdir=Data/mongoDatabases/recipes/kubernetes/terraform init -backend=false
terraform -chdir=Data/mongoDatabases/recipes/kubernetes/terraform validate
terraform -chdir=Data/mongoDatabases/recipes/kubernetes/terraform test
```

The Bicep test uses the Radius-bundled compiler at `~/.rad/bin/bicep`; set
`BICEP_CLI` to override it. The Terraform tests mock Kubernetes and use the real
local random provider. They check credential reuse, password URI escaping, the
namespace, persistent storage, and cleanup IDs without contacting a cluster.

For deployment checks, use a dedicated test cluster and follow the
[testing guide](../../docs/contributing/testing-resource-types-recipes.md).
Publish each recipe with these commands, then register it in the test
Environment or generate and attach its Recipe Pack before deploying
[`test/app.bicep`](test/app.bicep). Supply a secure `mongoPassword` recipe
parameter for the Bicep test.

```bash
make build-bicep-recipe RECIPE_PATH=Data/mongoDatabases/recipes/kubernetes/bicep/kubernetes-mongodb.bicep
make build-terraform-recipe RECIPE_PATH=Data/mongoDatabases/recipes/kubernetes/terraform
```

The intended shared Bicep publication source is
`ghcr.io/radius-project/kube-recipes/mongodatabases:<source-commit>`.
Its central publication workflow entry and the default Recipe Pack are managed
separately. The local Bicep build publishes to
`localhost:5000/radius-recipes/data/mongodatabases/kubernetes/bicep/kubernetes-mongodb:latest`.
The local Terraform module server serves `mongoDatabases-kubernetes.zip`.

## Using the resource type

Add a `mongoDatabases` resource to your application and connect a container to it. With Radius control-plane support from `radius-project/radius#12709` and Kubernetes Container Recipe support from `resource-types-contrib#300` or later, one connection named `mongodb` injects ordinary `CONNECTION_MONGODB_DATABASE` and `CONNECTION_MONGODB_ENDPOINT` values plus the secret-backed `CONNECTION_MONGODB_CONNECTIONSTRING`. No second managed-Secret connection is needed on compatible Kubernetes versions. For custom or backward-compatible Kubernetes configuration, `mongo.properties.secrets.name` remains available as the `secretName` for an explicitly authored `secretKeyRef`. See [`test/app.bicep`](test/app.bicep) for the gradual-adoption example.
