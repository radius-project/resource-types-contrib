# Kubernetes Recipe for Radius.Storage/objectStorage (Terraform)

## Recipe Description

This Terraform module runs a single-node [RustFS](https://github.com/rustfs/rustfs) server, an S3-compatible object store, in the Environment's namespace. It creates a `Deployment`, a `ClusterIP` `Service`, a 1 GiB `PersistentVolumeClaim` and a `Secret` with the generated credentials, then creates the bucket named by `containerName`. It is meant for development and testing: there is no TLS. The secret key comes from `random_password` and is kept in the Terraform state, so it stays the same when the Recipe runs again.

See the [resource type README](../../../README.md#kubernetes-recipe) for the behavior, limits and outputs.

## Usage Instructions

The checked-in Kubernetes Recipe Pack, [`recipe-packs/kubernetes/default.bicep`](../../../../../recipe-packs/kubernetes/default.bicep), registers only Bicep Recipes published to GHCR, so it does not reference this module. Host the module (for example as a zip archive of this directory on an HTTP server), then register it in a Recipe Pack:

```bicep
resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'objectstorage-terraform'
  properties: {
    recipes: {
      'Radius.Storage/objectStorage': {
        kind: 'terraform'
        source: '<URL of the hosted module>'
      }
    }
  }
}
```

The repository's CI does the same with `make generate-recipe-pack PACK_NAME=terraformrecipepack`, which serves every Terraform Recipe from an in-cluster module server. Clients use path-style S3 requests against `endpoint`, with `accountName` as the access key ID and `secrets.accountKey` as the secret access key. See [`test/app.bicep`](../../../test/app.bicep) for a container that reads the secrets.
