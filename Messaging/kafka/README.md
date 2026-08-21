# Radius.Messaging/kafka

## Overview

The **Radius.Messaging/kafka** resource type represents a Kafka-compatible messaging namespace. It allows developers to create a topic and easily connect containers to the messaging endpoint as part of their Radius applications. The developer provides only the `topic` property; the platform Recipe provisions the backing service and maps read-only connection properties such as `host` and `connectionString` back onto the resource.

Developer documentation is embedded in the resource type definition YAML file and is accessible via the `rad resource-type show Radius.Messaging/kafka` command.

## Properties

| Property | Type | Access | Description |
| --- | --- | --- | --- |
| `environment` | string | Required | The Radius Environment ID. Typically set by the `rad` CLI. |
| `application` | string | Optional | The Radius Application ID. |
| `topic` | string | Optional | The Kafka topic/Event Hub name to create. Defaults to `events`. |
| `host` | string | Read only | The host name used to connect to the Kafka-compatible endpoint. Set from the Recipe module's output. |
| `secrets` | object | Read only | Recipe secrets. `secrets.name` references the managed `Radius.Security/secrets` resource; `secrets.connectionString` is the secret key (delivered via that managed secret, never stored on the resource). |

## Naming constraints

`topic` is used verbatim as a cloud resource name, so from API version `2026-09-01-preview` it
carries format constraints. Radius validates it when the resource is submitted, which means a bad
value is rejected before a Recipe runs and before a billable namespace exists. API version
`2025-08-01-preview` is unconstrained and unchanged.

| Property | Accepted format |
| --- | --- |
| `topic` | 1-249 characters of letters, digits, periods, underscores or hyphens. Must start and end with a letter or a digit. |

The 249 character limit is Kafka's, not the Event Hubs limit of 256, so the same topic name works
against either backend. The start and end rule also rules out the Kafka reserved names `.` and
`..` and the reserved `__` prefix, so those need no separate note.

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Messaging/kafka` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure/bicep-recipepack.bicep`](../../recipe-packs/azure/bicep-recipepack.bicep) | Direct module — Azure Verified Module `avm/res/event-hub/namespace` |

## Using the resource type

Add a `kafka` resource to your application and connect a container to it. Radius injects the Kafka connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_KAFKA_HOST`). The `connectionString` secret is not injected — bind it from the managed `Radius.Security/secrets` resource with a container `secretKeyRef` using `kafka.properties.secrets.name`. See [`test/app.bicep`](test/app.bicep) for a complete example.
