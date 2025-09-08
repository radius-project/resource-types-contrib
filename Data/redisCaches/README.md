## Overview

The Radius.Data/redisCaches Resource Type represents Redis, a popular in-memory data structure store used as a cache or database. This Resource Type allows developers to create and manage Redis cache instances as part of their Radius applications.

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Data/redisCaches`.

## Recipes

A list of available Recipes for this Resource Type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Bicep | kubernetes-redis.bicep | Alpha |
| Kubernetes | Terraform | kubernetes/main.tf | Alpha |

## Recipe Input Properties

Properties for the redisCaches resource are provided to the Recipe via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.properties.capacity`(enum, optional): The capacity of the Redis server. Available options are S-Small, M-Medium, and L-Large. This property allows the developer to specify the size of the Redis cache instance. If not specified, Recipes should assume `S` as the capacity.

## Recipe Output Properties

The Redis resource has the following output properties that will be set by a Recipe:

- `context.properties.hostname` (string, read-only): The hostname used to connect to the Redis server.
- `context.properties.port` (integer, read-only): The port number used to connect to the Redis server.
- `context.properties.tls` (boolean, read-only): Indicates if TLS is enabled for the Redis server.
- `context.properties.secrets.username` (string, read-only): The username for connecting to the Redis server.
- `context.properties.secrets.password` (string, read-only): The password for connecting to the Redis server.
