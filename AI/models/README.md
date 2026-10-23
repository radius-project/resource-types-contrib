# Radius.AI/models

## Overview

The **Radius.AI/models** resource type represents an LLM inference model endpoint. It allows developers to provision and connect to a managed model service as part of their Radius applications. The resource has no developer-authored credentials; the platform Recipe provisions the concrete model service and maps its endpoint and API key back onto read-only resource properties for connections.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.AI/models` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `model` | string | Optional | The model deployment to provision. Defaults to `gpt-5-mini`. |
| `endpoint` | string | Read only | The base URL used to call the model inference endpoint. Set from the Recipe module's output. |
| `secrets` | object | Read only | Recipe secrets. `secrets.name` references the managed `Radius.Security/secrets` resource; `secrets.apiKey` is the secret key (delivered via that managed secret, never stored on the resource). |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.AI/models` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure-aks/azure-aks.bicep`](../../recipe-packs/azure-aks/azure-aks.bicep) | Direct module — Azure Verified Module `mcr.microsoft.com/bicep/avm/res/cognitive-services/account:0.15.0` |

### Kubernetes Recipe

The Kubernetes Recipe ([`recipes/kubernetes/terraform`](recipes/kubernetes/terraform)) runs an [Ollama](https://ollama.com) server from the official `ollama/ollama` image in the Environment's namespace and serves an open-weight model on the CPU through Ollama's OpenAI-compatible API. It is meant for development and testing:

- `model` is the name clients send in API requests. Hosted OpenAI model names have no open weights, so when `model` starts with `gpt-` (for example the default `gpt-5-mini`), the Recipe serves `qwen2.5:0.5b` (Qwen2.5 0.5B Instruct, Apache 2.0, about 400 MB) under that name. The open-weight `gpt-oss` family is the exception and is pulled as named. Any other value is pulled as-is from the [Ollama library](https://ollama.com/library), for example `llama3.2:1b`.
- The model is downloaded when the Pod starts and stored in an `emptyDir` volume, so it is downloaded again whenever the Pod is replaced. The Pod reports ready only after the model is available. The deployment does not wait for this, so a client that starts at the same time should retry until the endpoint responds. If the download still fails after five attempts, the container exits with an error and Kubernetes restarts it.
- The image is several gigabytes because it bundles GPU runtimes, which this Recipe does not use, so the first deployment on a node takes a few minutes.
- The first request after the server starts, or after the model has been idle for five minutes, loads the model into memory.
- Ollama does not authenticate requests. Any Pod that can reach the `Service` can call it.

| Output | Value |
| --- | --- |
| `endpoint` | The OpenAI-compatible base URL, `http://<resource-name>.<namespace>.svc.cluster.local:11434/v1`. |
| `secrets.apiKey` | The placeholder `ollama`. Ollama ignores it, but OpenAI client libraries require a non-empty API key. Delivered through the managed secret. |

The checked-in Kubernetes Recipe Pack, [`recipe-packs/kubernetes/default.bicep`](../../recipe-packs/kubernetes/default.bicep), registers only Bicep Recipes published to GHCR, so it does not reference this Terraform module. To use the module, add a `Radius.AI/models` entry with `kind: 'terraform'` to a Recipe Pack and set its `source` to the location where you host the module, as the repository's CI does when it tests Terraform Recipes.

## Using the resource type

Add a `models` resource to your application and connect a container to it. With Radius control-plane support from `radius-project/radius#12709` and Kubernetes Container Recipe support from `resource-types-contrib#300` or later, one connection named `llm` injects ordinary `CONNECTION_LLM_MODEL` and `CONNECTION_LLM_ENDPOINT` values plus the secret-backed `CONNECTION_LLM_APIKEY`. No second managed-Secret connection is needed on compatible Kubernetes versions. For custom or backward-compatible Kubernetes configuration, `model.properties.secrets.name` remains available as the `secretName` for an explicitly authored `secretKeyRef`. See [`test/app.bicep`](test/app.bicep) for the gradual-adoption example.
