# Radius.Messaging/rabbitMQ

## Overview

The **Radius.Messaging/rabbitMQ** resource type represents a RabbitMQ message broker that speaks AMQP 0-9-1. It allows developers to create and connect to a queue as part of their Radius applications.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.Messaging/rabbitMQ` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `queue` | string | Optional | The name of the queue to pre-provision on the broker. The Recipe creates this durable queue when the broker starts. Defaults to `jobs`. |
| `username` | string | Optional | The username the broker is provisioned with. Defaults to `radius`. Avoid `guest` (loopback-only in RabbitMQ). Not sensitive; exposed as a read-only connection value. |
| `password` | string | Required | The resource ID of the `Radius.Security/secrets` resource that holds the broker password under key `password` (set to `<secretResource>.id`). The Recipe mounts the password into the broker via `secretKeyRef`, so the plaintext password never lands in the pod spec or on this resource. |
| `host` | string | Read only | The host name used to connect to the broker. Set from the Recipe's Service DNS name. |
| `port` | integer | Read only | The port used to connect to the broker over AMQP 0-9-1 (5672). Set from the Recipe's output. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Messaging/rabbitMQ` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure-aks/azure-aks.bicep`](../../recipe-packs/azure-aks/azure-aks.bicep) | In-cluster RabbitMQ `Deployment` + `Service` on AKS [`recipes/kubernetes`](recipes/kubernetes) |
| Kubernetes | [`recipe-packs/kubernetes/default.bicep`](../../recipe-packs/kubernetes/default.bicep) | In-cluster RabbitMQ `Deployment` + `Service` [`recipes/kubernetes`](recipes/kubernetes) |

## Using the resource type

Create a `Radius.Security/secrets` resource holding the broker `password` (from a `@secure()` parameter), add a `rabbitMQ` resource that references it via `password`, and connect a container to the broker. Radius injects the queue's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_RABBITMQ_HOST`, `CONNECTION_RABBITMQ_PORT`, `CONNECTION_RABBITMQ_USERNAME`). The password is not emitted by this resource — read it from the same `Radius.Security/secrets` resource with a container `secretKeyRef` (`secretName: rabbitmqSecret.name`, key `password`). See [`test/app.bicep`](test/app.bicep) for a complete example.
