# Kubernetes Recipe for Radius.AI/models (Bicep)

## Recipe Description

[`kubernetes-ollama.bicep`](kubernetes-ollama.bicep) runs an [Ollama](https://ollama.com) server from the official `ollama/ollama` image and serves an open-weight model on the CPU through Ollama's OpenAI-compatible API. It creates a single-replica `Deployment` and a `ClusterIP` `Service`, both named after the resource, in the Environment's namespace. It is meant for development and testing.

See the [resource type README](../../../README.md#kubernetes-recipe) for how `model` is mapped to an open-weight model, the startup behavior, the limits, and the outputs.

## Usage Instructions

The default Kubernetes Recipe Pack, [`recipe-packs/kubernetes/default.bicep`](../../../../../recipe-packs/kubernetes/default.bicep), registers this Recipe for `Radius.AI/models` from `ghcr.io/radius-project/kube-recipes/models`. Deploy the pack and associate it with your Environment as described in the [Kubernetes Recipe Pack README](../../../../../recipe-packs/kubernetes/README.md). The Recipe takes no parameters.

The deployment completes before the model is downloaded. To wait until the model can serve requests:

```bash
kubectl wait -n <namespace> --for=condition=Available deploy/<resource-name> --timeout=15m
```
