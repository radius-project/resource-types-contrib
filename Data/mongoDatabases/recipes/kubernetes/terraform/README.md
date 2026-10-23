# Kubernetes Recipe for Radius.Data/mongoDatabases (Terraform)

## Recipe Description

This Terraform module runs a single MongoDB server from the official `mongo` image in the Environment's namespace, with authentication enabled. It creates a `Deployment`, a `ClusterIP` `Service` on port `27017`, and a `Secret` with the generated administrator credentials. It is meant for development and testing: there is no TLS and storage is an `emptyDir` volume. The administrator password comes from `random_password` and is kept in the Terraform state, so it stays the same when the Recipe runs again.

See the [resource type README](../../../README.md#kubernetes-recipe) for the behavior, limits and outputs.

## Usage Instructions

The checked-in Kubernetes Recipe Pack, [`recipe-packs/kubernetes/default.bicep`](../../../../../recipe-packs/kubernetes/default.bicep), registers only Bicep Recipes published to GHCR, so it does not reference this module. Host the module (for example as a zip archive of this directory on an HTTP server), then register it in a Recipe Pack:

```bicep
resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'mongodatabases-terraform'
  properties: {
    recipes: {
      'Radius.Data/mongoDatabases': {
        kind: 'terraform'
        source: '<URL of the hosted module>'
      }
    }
  }
}
```

The repository's CI does the same with `make generate-recipe-pack PACK_NAME=terraformrecipepack`, which serves every Terraform Recipe from an in-cluster module server. Clients connect with `secrets.connectionString`, which already contains the credentials, the database and `authSource=admin`. See [`test/app.bicep`](../../../test/app.bicep) for a container that reads it from the managed secret.
