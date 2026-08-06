# Radius.Messaging/rabbitMQ

## Overview

The **Radius.Messaging/rabbitMQ** resource type represents a RabbitMQ message broker that speaks AMQP 0-9-1. It allows developers to create and connect to a queue as part of their Radius applications.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.Messaging/rabbitMQ` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `queue` | string | Optional | The logical queue name your application declares. RabbitMQ creates queues on demand, so the Recipe does not pre-provision it. |
| `host` | string | Read only | The host or namespace name used to connect to the queue. Set from the Recipe module's output. |
| `secrets` | object | Read only | Recipe secrets. `secrets.name` references the managed `Radius.Security/secrets` resource; `secrets.connectionString` is the secret key (delivered via that managed secret, never stored on the resource). |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Messaging/rabbitMQ` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure/aks-recipepack.bicep`](../../recipe-packs/azure/aks-recipepack.bicep) | In-cluster RabbitMQ `Deployment` + `Service` on AKS [`recipes/kubernetes`](recipes/kubernetes) |
| Kubernetes | [`recipe-packs/kubernetes/default-recipepack.bicep`](../../recipe-packs/kubernetes/default-recipepack.bicep) | In-cluster RabbitMQ `Deployment` + `Service` [`recipes/kubernetes`](recipes/kubernetes) |

> **Note:** The Azure Recipe Pack provisions this type by running the official `rabbitmq` container on the target AKS cluster rather than a managed Azure service. Azure has no first-party managed RabbitMQ, and Azure Service Bus exposes AMQP 1.0 (with an `Endpoint=sb://...` connection string) rather than RabbitMQ's native AMQP 0-9-1 wire protocol, so it is not a drop-in RabbitMQ broker. The Azure/AKS recipe therefore deploys a real RabbitMQ broker container and emits an `amqp://user:pass@host:5672` connection string that RabbitMQ clients connect to directly.

## Using the resource type

Add a `rabbitMQ` resource to your application and connect a container to it. Radius injects the queue's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_RABBITMQ_HOST`). The `connectionString` secret is not injected — bind it from the managed `Radius.Security/secrets` resource with a container `secretKeyRef` using `rabbitmq.properties.secrets.name`. See [`test/app.bicep`](test/app.bicep) for a complete example.
