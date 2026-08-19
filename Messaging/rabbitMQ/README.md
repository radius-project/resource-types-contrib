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
| `password` | string | Optional | The resource ID of a `Radius.Security/secrets` resource containing the broker password under key `password`. If omitted, the Kubernetes Recipe generates a random password and returns it through a managed secret. |
| `host` | string | Read only | The host name used to connect to the broker. Set from the Recipe's Service DNS name. |
| `port` | integer | Read only | The port used to connect to the broker over AMQP 0-9-1 (5672). Set from the Recipe's output. |
| `secrets` | object | Read only | Managed Recipe secrets created when `password` is omitted. Use `secrets.name` as the `secretName` and `password` as the key in a container `secretKeyRef`. |

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Messaging/rabbitMQ` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure-aks/azure-aks.bicep`](../../recipe-packs/azure-aks/azure-aks.bicep) | In-cluster RabbitMQ `Deployment` + `Service` on AKS [`recipes/kubernetes`](recipes/kubernetes) |
| Kubernetes | [`recipe-packs/kubernetes/default.bicep`](../../recipe-packs/kubernetes/default.bicep) | In-cluster RabbitMQ `Deployment` + `Service` [`recipes/kubernetes`](recipes/kubernetes) |

## Using the resource type

Add a `rabbitMQ` resource and connect a container to it. You can provide the ID of a `Radius.Security/secrets` resource through `password`; the broker uses its materialized Kubernetes Secret directly. If you omit `password`, the Kubernetes Recipe creates broker credentials with a random fallback and Radius materializes the same value into a managed `Radius.Security/secrets` resource. Bind the supplied or generated secret with a container `secretKeyRef` using key `password`. Radius injects the queue's non-secret connection properties as `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` variables. See [`test/app.bicep`](test/app.bicep) for a complete fallback example.
