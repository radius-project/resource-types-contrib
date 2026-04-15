# Radius.Data/redisCaches

## Overview

The **Radius.Data/redisCaches** resource type represents a Redis cache. It allows developers to create and easily connect to a Redis cache as part of their Radius applications.

Developer documentation is embedded in the resource type definition YAML file, and it is accessible via the `rad resource-type show Radius.Data/redisCaches` command.

## Recipes

A list of available Recipes for this resource type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Bicep | kubernetes-redis.bicep | Alpha |
| Kubernetes | Terraform | main.tf | Alpha |

## Recipe Input Properties

Properties for the **Radius.Data/redisCaches** resource type are provided via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.properties.size`(string, optional): The size of the Redis cache. Defaults to `S` if not provided.
- `context.properties.secretName`(string, optional): The name of the secret containing the Redis password. If not provided, Redis runs without authentication.

## Recipe Output Properties

The **Radius.Data/redisCaches** resource type expects the following output properties to be set in the Results object in the Recipe:

- `context.properties.host` (string): The hostname used to connect to the cache.
- `context.properties.port` (integer): The port number used to connect to the cache.
