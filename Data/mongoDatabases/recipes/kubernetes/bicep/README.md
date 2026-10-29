# Kubernetes Recipe for Radius.Data/mongoDatabases (Bicep)

## Recipe Description

[`kubernetes-mongodb.bicep`](kubernetes-mongodb.bicep) runs a single MongoDB server from the official `mongo` image in the Environment's namespace, with authentication enabled. It creates a `Deployment`, a `ClusterIP` `Service` on port `27017`, and a `Secret` with the generated administrator credentials. It is meant for development and testing: there is no TLS, storage is an `emptyDir` volume, and a new administrator password is generated on each deployment.

See the [resource type README](../../../README.md#kubernetes-recipe) for the behavior, limits and outputs.

## Usage Instructions

The Recipe is registered for `Radius.Data/mongoDatabases` in the default Kubernetes Recipe Pack, [`recipe-packs/kubernetes/default.bicep`](../../../../../recipe-packs/kubernetes/default.bicep), as `ghcr.io/radius-project/kube-recipes/mongodatabases`. Deploy that pack into an Environment and associate it, then add a `mongoDatabases` resource to an application:

```bicep
resource mongo 'Radius.Data/mongoDatabases@2025-08-01-preview' = {
  name: 'mongo'
  properties: {
    environment: environment
    application: app.id
    database: 'mongo_db'
  }
}
```

Clients connect with `secrets.connectionString`, which already contains the credentials, the database and `authSource=admin`. See [`test/app.bicep`](../../../test/app.bicep) for a container that reads it from the managed secret.
