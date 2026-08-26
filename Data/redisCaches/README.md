# Radius.Data/redisCaches

## Overview

The **Radius.Data/redisCaches** resource type represents a Redis cache. It allows developers to create and easily connect to a Redis cache as part of their Radius applications. Unlike database types, no credential has to be supplied — the platform's Recipe provisions a cache that generates its own access key, so no credentials need to be injected.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.Data/redisCaches` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `size` | string (`S`, `M`, `L`) | Optional | The size of the Redis cache. Defaults to `S`. The Recipe maps the size onto a concrete cloud SKU. |
| `host` | string | Read only | The host name used to connect to the cache. Set from the Recipe module's output. |
| `port` | integer | Read only | The TLS port number used to connect to the cache. Set from the Recipe module's output. |
| `secrets` | object | Read only | Recipe secrets. `secrets.name` references the managed `Radius.Security/secrets` resource; `secrets.url` and `secrets.accessKey` are secret keys (delivered via that managed secret, never stored on the resource). |

### Secret keys

| Key | Description | Mapped by |
| --- | --- | --- |
| `url` | Full connection URL including the access key, for clients that parse one. | All Recipes. |
| `accessKey` | The access key on its own, for clients that take host, port, and password separately — it is the password such a client authenticates with. | Recipes that provision an authenticated cache. The in-cluster Kubernetes Recipe provisions a cache with no credential and does not map this key. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/redisCaches` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure/bicep-recipepack.bicep`](../../recipe-packs/azure/bicep-recipepack.bicep) | Direct module — Azure Verified Module `avm/res/cache/redis-enterprise` |
| Kubernetes | [`recipe-packs/kubernetes/default-recipepack.bicep`](../../recipe-packs/kubernetes/default-recipepack.bicep) | In-cluster Redis `Deployment` + `Service` [`recipes/kubernetes`](recipes/kubernetes) |

## Using the resource type

Add a `redisCaches` resource to your application and connect a container to it. Radius injects the cache's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_REDIS_HOST` and `CONNECTION_REDIS_PORT`). The secrets are not injected — bind one from the managed `Radius.Security/secrets` resource with a container `secretKeyRef` using `redis.properties.secrets.name`, choosing `url` for a URL-parsing client or `accessKey` for a client configured with host, port, and password separately. See [`test/app.bicep`](test/app.bicep) for a complete example.
