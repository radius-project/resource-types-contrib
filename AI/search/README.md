# Radius.AI/search

## Overview

The **Radius.AI/search** resource type represents a search service. It allows developers to create and connect to a search service as part of their Radius applications. The resource has no developer-authored credentials; the platform Recipe maps the provisioned service endpoint and API key back onto read-only resource properties for connections.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.AI/search` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `endpoint` | string | Read only | The endpoint used to connect to the search service. Set from the Recipe module's output. |
| `secrets` | object | Read only | Recipe secrets. `secrets.name` references the managed `Radius.Security/secrets` resource; `secrets.apiKey` is the secret key (delivered via that managed secret, never stored on the resource). |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.AI/search` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure-aks/azure-aks.bicep`](../../recipe-packs/azure-aks/azure-aks.bicep) | Direct module — Azure Verified Module `mcr.microsoft.com/bicep/avm/res/search/search-service:0.12.2` |

### Kubernetes Terraform Recipe

A Kubernetes Recipe for this resource type is available as a Terraform module, [`recipes/kubernetes/terraform`](recipes/kubernetes/terraform). It runs a [Meilisearch](https://www.meilisearch.com) server from the official `getmeili/meilisearch` image in the Environment's namespace and is meant for development and testing. The checked-in Kubernetes Recipe Pack registers only Bicep Recipes, so register the module in a Recipe Pack of your own, as described in its [README](recipes/kubernetes/terraform/README.md).

- Meilisearch has its own REST API. It is not compatible with the Azure AI Search API, so the Kubernetes Recipe makes the resource and its connection (`endpoint` and `apiKey`) portable, not application code written against a particular search service.
- The module generates a random master key, keeps it in the Terraform state, and returns it as `apiKey`. Every request except `GET /health` must send it as `Authorization: Bearer <apiKey>`. The server runs in production mode, which requires the key and turns off the built-in search preview UI, and with telemetry turned off.
- Indexes are stored in an `emptyDir` volume, so they are lost whenever the Pod is replaced.

| Output | Value |
| --- | --- |
| `endpoint` | The base URL of the Meilisearch REST API, `http://<resource-name>.<namespace>.svc.cluster.local:7700`. |
| `secrets.apiKey` | The generated master key. Delivered through the managed secret. |

## Using the resource type

Add a `search` resource to your application and connect a container to it. With Radius control-plane support from `radius-project/radius#12709` and Kubernetes Container Recipe support from `resource-types-contrib#300` or later, one connection named `search` injects the ordinary `CONNECTION_SEARCH_ENDPOINT` value plus the secret-backed `CONNECTION_SEARCH_APIKEY`. No second managed-Secret connection is needed on compatible Kubernetes versions. For custom or backward-compatible Kubernetes configuration, `search.properties.secrets.name` remains available as the `secretName` for an explicitly authored `secretKeyRef`. See [`test/app.bicep`](test/app.bicep) for the gradual-adoption example.
