# Kubernetes Recipe for Radius.AI/models (Terraform)

## Recipe Description

This Terraform module ([`main.tf`](main.tf), [`var.tf`](var.tf)) runs an [Ollama](https://ollama.com) server from the official `ollama/ollama` image and serves an open-weight model on the CPU through Ollama's OpenAI-compatible API. It creates a single-replica `Deployment` and a `ClusterIP` `Service`, both named after the resource, in the Environment's namespace. It is meant for development and testing.

See the [resource type README](../../../README.md#kubernetes-recipe) for how `model` is mapped to an open-weight model, the startup behavior, the limits, and the outputs.

## Usage Instructions

The checked-in Kubernetes Recipe Pack registers only Bicep Recipes, so register this module in a Recipe Pack of your own with `kind: 'terraform'`. Set `source` to a Terraform module source that Radius can download, for example an HTTP URL of a zip of this directory, which is how the repository's CI tests it:

```bicep
'Radius.AI/models': {
  kind: 'terraform'
  source: '<module source>'
}
```

The module needs only the `context` variable, which Radius sets. It does not wait for the model download (`wait_for_rollout = false`). To wait until the model can serve requests:

```bash
kubectl wait -n <namespace> --for=condition=Available deploy/<resource-name> --timeout=15m
```
