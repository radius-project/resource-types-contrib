# Kubernetes Recipe for Radius.AI/search (Bicep)

## Recipe Description

[`kubernetes-meilisearch.bicep`](kubernetes-meilisearch.bicep) runs a [Meilisearch](https://www.meilisearch.com) server from the official `getmeili/meilisearch` image. It creates a single-replica `Deployment` and a `ClusterIP` `Service`, both named after the resource plus a hash of its resource ID, a `PersistentVolumeClaim` for the indexes, and a `Secret` that holds the generated master key, in the Environment's namespace. It is meant for development and testing.

See the [resource type README](../../../README.md#kubernetes-recipe) for what the Recipe provides, its limits, and the outputs.

## Usage Instructions

The default Kubernetes Recipe Pack, [`recipe-packs/kubernetes/default.bicep`](../../../../../recipe-packs/kubernetes/default.bicep), registers this Recipe for `Radius.AI/search` from `ghcr.io/radius-project/kube-recipes/search`. Deploy the pack and associate it with your Environment as described in the [Kubernetes Recipe Pack README](../../../../../recipe-packs/kubernetes/README.md). The Recipe takes no parameters.
