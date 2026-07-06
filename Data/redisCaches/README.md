# Radius.Data/redisCaches

## Overview

The **Radius.Data/redisCaches** resource type represents a Redis cache. It allows developers to create and easily connect to a Redis cache as part of their Radius applications. Unlike database types, no secret is required — the platform's Recipe provisions a cache that generates its own access keys, so no credentials need to be injected.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.Data/redisCaches` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `size` | string (`S`, `M`, `L`) | Optional | The size of the Redis cache. Defaults to `S`. The Recipe maps the size onto a concrete cloud SKU. |
| `host` | string | Read only | The host name used to connect to the cache. Set from the Recipe module's output. |
| `port` | integer | Read only | The TLS port number used to connect to the cache. Set from the Recipe module's output. |
| `url` | string | Read only | The full TLS connection URL (`rediss://:<access-key>@<host>:<port>`), including the access key. Set from the Recipe module's output. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipepack/`](../../recipepack). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/redisCaches` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipepack/azure/bicep-recipepack.bicep`](../../recipepack/azure/bicep-recipepack.bicep) | Direct module — Azure Verified Module `avm/res/cache/redis-enterprise` |

## Using the resource type

Add a `redisCaches` resource to your application and connect a container to it. Radius injects the cache's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_REDIS_HOST`, `CONNECTION_REDIS_PORT`, and `CONNECTION_REDIS_URL`). See [`test/app.bicep`](test/app.bicep) for a complete example.
