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
| `apiKey` | string | Read only | The API key used to call the model inference endpoint. Set from the Recipe module's output. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipepack/`](../../recipepack). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.AI/models` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipepack/azure/bicep-recipepack.bicep`](../../recipepack/azure/bicep-recipepack.bicep) | Direct module — Azure Verified Module `mcr.microsoft.com/bicep/avm/res/cognitive-services/account:0.15.0` |

## Using the resource type

Add a `models` resource to your application and connect a container to it. Radius injects the model's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_LLM_MODEL`, `CONNECTION_LLM_ENDPOINT`, and `CONNECTION_LLM_APIKEY`). See [`test/app.bicep`](test/app.bicep) for a complete example.
