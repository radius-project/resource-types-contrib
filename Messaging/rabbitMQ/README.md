# Radius.Messaging/rabbitMQ

## Overview

The **Radius.Messaging/rabbitMQ** resource type represents a queue-compatible messaging resource. It allows developers to create and connect to a queue as part of their Radius applications. The Azure Recipe Pack provisions this type with Azure Service Bus via the Service Bus AMQP endpoint.

> **Note:** Azure Service Bus exposes AMQP 1.0 but is not a RabbitMQ broker and does not provide RabbitMQ's native AMQP 0-9-1 wire protocol. The validated Azure recipe verifies provisioning and AMQP 1.0 connectivity rather than RabbitMQ-native broker compatibility.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.Messaging/rabbitMQ` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `queue` | string | Optional | The queue name to create. Defaults to `jobs`. |
| `host` | string | Read only | The host or namespace name used to connect to the queue. Set from the Recipe module's output. |
| `secrets` | object | Read only | Recipe secrets. `secrets.name` references the managed `Radius.Security/secrets` resource; `secrets.connectionString` is the secret key (delivered via that managed secret, never stored on the resource). |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipepack/`](../../recipepack). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Messaging/rabbitMQ` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipepack/azure/bicep-recipepack.bicep`](../../recipepack/azure/bicep-recipepack.bicep) | Direct module — Azure Verified Module `avm/res/service-bus/namespace` |

## Using the resource type

Add a `rabbitMQ` resource to your application and connect a container to it. Radius injects the queue's connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_RABBITMQ_HOST`). The `connectionString` secret is not injected — bind it from the managed `Radius.Security/secrets` resource with a container `secretKeyRef` using `rabbitmq.properties.secrets.name`. See [`test/app.bicep`](test/app.bicep) for a complete example.
