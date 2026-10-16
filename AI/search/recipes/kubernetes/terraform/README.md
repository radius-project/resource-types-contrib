# Kubernetes Recipe for Radius.AI/search (Terraform)

## Recipe Description

This Terraform module ([`main.tf`](main.tf), [`var.tf`](var.tf)) runs a [Meilisearch](https://www.meilisearch.com) server from the official `getmeili/meilisearch` image in the Environment's namespace. It creates a single-replica `Deployment` and a `ClusterIP` `Service`, both named after the resource, and a `Secret` that holds a generated master key. It is meant for development and testing.

See the [resource type README](../../../README.md#kubernetes-terraform-recipe) for what the module provides, its limits, and the outputs.

## Usage Instructions

The checked-in Kubernetes Recipe Pack registers only Bicep Recipes, so register this module in a Recipe Pack of your own with `kind: 'terraform'`. Set `source` to a Terraform module source that Radius can download, for example an HTTP URL of a zip of this directory, which is how the repository's CI tests it:

```bicep
'Radius.AI/search': {
  kind: 'terraform'
  source: '<module source>'
}
```

The module needs only the `context` variable, which Radius sets. It uses the `hashicorp/kubernetes` and `hashicorp/random` providers. The generated master key is kept in the Terraform state, so it stays the same when the resource is deployed again.
