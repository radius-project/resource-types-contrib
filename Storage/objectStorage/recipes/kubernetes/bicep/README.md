# Kubernetes Recipe for Radius.Storage/objectStorage (Bicep)

## Recipe Description

[`kubernetes-objectstorage.bicep`](kubernetes-objectstorage.bicep) runs a single-node [RustFS](https://github.com/rustfs/rustfs) server, an S3-compatible object store, in the Environment's namespace. It creates a `Deployment`, a `ClusterIP` `Service`, a 1 GiB `PersistentVolumeClaim` and a `Secret` with the generated credentials, then creates the bucket named by `containerName`. It is meant for development and testing: there is no TLS, and a new secret key is generated on each deployment.

See the [resource type README](../../../README.md#kubernetes-recipe) for the behavior, limits and outputs.

## Usage Instructions

The Recipe is registered for `Radius.Storage/objectStorage` in the default Kubernetes Recipe Pack, [`recipe-packs/kubernetes/default.bicep`](../../../../../recipe-packs/kubernetes/default.bicep), as `ghcr.io/radius-project/kube-recipes/objectstorage`. Deploy that pack into an Environment and associate it, then add an `objectStorage` resource to an application:

```bicep
resource store 'Radius.Storage/objectStorage@2025-08-01-preview' = {
  name: 'store'
  properties: {
    environment: environment
    application: app.id
    containerName: 'data'
  }
}
```

Clients use path-style S3 requests against `endpoint`, with `accountName` as the access key ID and `secrets.accountKey` as the secret access key. See [`test/app.bicep`](../../../test/app.bicep) for a container that reads the secrets.
