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
| `port` | integer | Read only | The connection port. Azure uses TLS on port 10000; Kubernetes uses port 6379 without TLS. |
| `secrets` | object | Read only | Recipe secrets. `secrets.name` references the managed `Radius.Security/secrets` resource. The other keys are delivered through that managed secret, never stored on the resource. The keys each cache has depend on its Recipe. See [Secret keys](#secret-keys). |

### Secret keys

| Key | Description | Mapped by |
| --- | --- | --- |
| `url` | Full connection URL including the access key, for clients that parse one. | All Recipes. |
| `accessKey` | The access key on its own, for clients that take host, port, and password separately — it is the password such a client authenticates with. | Recipes that provision an authenticated cache. The in-cluster Kubernetes Recipe provisions a cache with no credential and does not map this key. |
| `connectionString` | StackExchange.Redis connection string with the access key and TLS settings. This is not a Redis URL. | Azure Recipe only. |

The Azure Recipe uses `avm/res/cache/redis-enterprise:0.5.1`. In that
module, `primaryConnectionString` is a `rediss://:<key>@<host>:<port>` URL,
not a StackExchange.Redis connection string. The Recipe maps it to `url`,
maps `primaryAccessKey` to `accessKey`, and maps
`primaryStackExchangeRedisConnectionString` to `connectionString`.
TLS and access-key authentication are enabled.

Use `url` for Spring Data Redis, ioredis, redis-rb, and other URL clients.
Use `host`, `port`, and the secret `accessKey` for clients that accept a
separate password; enable TLS on Azure. Use `connectionString` for
StackExchange.Redis. Bind each secret with `secretKeyRef`; do not put its
value in application properties or logs.

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Data/redisCaches` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure-aks/azure-aks.bicep`](../../recipe-packs/azure-aks/azure-aks.bicep) | Direct module — Azure Verified Module `avm/res/cache/redis-enterprise` |
| Kubernetes | [`recipe-packs/kubernetes/default.bicep`](../../recipe-packs/kubernetes/default.bicep) | In-cluster Redis `Deployment` + `Service` [`recipes/kubernetes`](recipes/kubernetes) |

## Using the resource type

Add a `redisCaches` resource to your application and connect a container to it. With Radius control-plane support from `radius-project/radius#12709` and Kubernetes Container Recipe support from `resource-types-contrib#300` or later, one connection named `redis` injects ordinary `CONNECTION_REDIS_HOST` and `CONNECTION_REDIS_PORT` values plus a secret-backed variable for each key the selected Recipe returns in `result.secrets`: `CONNECTION_REDIS_URL`, and `CONNECTION_REDIS_ACCESSKEY` when the Recipe provides `accessKey`. For custom, older, or mixed-version Kubernetes deployments, bind the desired key explicitly with `secretKeyRef` using `redis.properties.secrets.name`; [`test/app.bicep`](test/app.bicep) retains this portable explicit wiring.

The Azure Recipe also injects `CONNECTION_REDIS_CONNECTIONSTRING` for
StackExchange.Redis clients. The test app checks the URL with `redis-cli`.
Azure Recipe Pack tests also check the URL format, the StackExchange.Redis
format, and a TLS connection with the separate access key.

To run this check against an existing Azure Environment with the updated
namespace and Recipe Pack:

```bash
RTC_TEST_PLATFORM=azure ./.github/scripts/test-recipe-pack-entry.sh Data/redisCaches default default
```
