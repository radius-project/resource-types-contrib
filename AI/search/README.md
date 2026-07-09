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

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipepack/`](../../recipepack). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.AI/search` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipepack/azure/bicep-recipepack.bicep`](../../recipepack/azure/bicep-recipepack.bicep) | Direct module — Azure Verified Module `mcr.microsoft.com/bicep/avm/res/search/search-service:0.12.2` |

## Using the resource type

Add a `search` resource to your application and connect a container to it. Radius injects the search service's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_SEARCH_ENDPOINT`). The `apiKey` secret is not injected — bind it from the managed `Radius.Security/secrets` resource with a container `secretKeyRef` using `search.properties.secrets.name`. See [`test/app.bicep`](test/app.bicep) for a complete example.
