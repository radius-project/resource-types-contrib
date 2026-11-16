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

## Recipe Packs

Recipes for this resource type are provided through the platform Recipe Packs at the repository root under [`recipe-packs/`](../../recipe-packs/). A platform engineer configures an Environment by deploying the Recipe Pack for their target platform, which registers the Recipe for `Radius.Messaging/kafka` along with the Recipes for every other Resource Type on that platform.

| Platform | Recipe Pack | Recipe source |
| --- | --- | --- |
| Azure | [`recipe-packs/azure-aks/azure-aks.bicep`](../../recipe-packs/azure-aks/azure-aks.bicep) | Direct module — Azure Verified Module `avm/res/event-hub/namespace` |
| Kubernetes | Register either recipe below in your Environment's Recipe Pack | [Bicep](recipes/kubernetes/bicep/kubernetes-kafka.bicep) or [Terraform](recipes/kubernetes/terraform/main.tf) |

## Kubernetes development recipes

Both recipes run one Apache Kafka 3.9.1 broker and KRaft controller, with a
ClusterIP Service and a 1 GiB ReadWriteOnce PVC in the Environment's Kubernetes
namespace. A default StorageClass with dynamic volume provisioning is required.
No extra recipe parameters or Kafka operator are required. The Pod runs as UID
and GID 1000; the storage driver must support `fsGroup: 1000`.

These recipes are for development only. They use plaintext with no authentication,
TLS, access control, or high availability. Use a private, trusted cluster and
restrict network access. Do not use these recipes for sensitive or production data.
The controller listener is not exposed by the Service. Topic creation and
readiness use a separate listener bound and advertised only on
`127.0.0.1:19092`. They do not need the Service endpoint before Kubernetes
publishes the Pod IP. The Service exposes only ready client endpoints on port
9092. Clients must retry connections during startup and updates.

The broker advertises `<resource-name>.<namespace>.svc.cluster.local:9092`,
not localhost. Clients must run in the same cluster, with the `cluster.local`
DNS domain. `values.host` is the Service FQDN. `secrets.connectionString` is
`<host>:9092`, a native Kafka `bootstrap.servers` value. Radius delivers it through
the managed secret described above, even though it contains no credentials.
It is **not** an Azure Event Hubs SAS connection string: clients must use the
Kafka protocol with `security.protocol=PLAINTEXT`, not the Event Hubs SDK or
Event Hubs SASL settings. The existing Azure sample container is not a native
Kafka round-trip test.

The startup hook waits for Kafka, then creates `topic` (default `events`) with one
partition and replication factor one. It rejects invalid and internal topic names,
and does not recreate an existing topic. Readiness checks that the topic exists.
Changing `topic` rolls the Pod and creates the new topic; it does not delete old
topics. Automatic topic creation is disabled. The fixed KRaft cluster ID remains
stable across restarts; each broker uses its own PVC and isolated controller quorum.

The Deployment uses `Recreate`, so updates cause downtime but do not start two
brokers on the same data. The PVC preserves data across Pod replacement. Radius
tracks the Deployment, Service, and PVC for cleanup. Deleting the Radius resource
deletes the claim; the StorageClass reclaim policy controls whether the underlying
volume is deleted or retained. This is not a backup.

### Validation

Run these checks from the repository root:

```bash
node --test .github/scripts/tests/test-kafka-kubernetes.js
terraform -chdir=Messaging/kafka/recipes/kubernetes/terraform init -backend=false
terraform -chdir=Messaging/kafka/recipes/kubernetes/terraform validate
terraform -chdir=Messaging/kafka/recipes/kubernetes/terraform test
shellcheck Messaging/kafka/recipes/kubernetes/{bicep,terraform}/create-topic.sh
```

In a dedicated local test environment with an OCI registry on port 5000, publish
the Bicep recipe using the Radius-bundled compiler:

```bash
rad bicep publish --file Messaging/kafka/recipes/kubernetes/bicep/kubernetes-kafka.bicep \
  --target br:localhost:5000/radius-recipes/messaging/kafka/recipes/kubernetes/bicep/kubernetes-kafka:latest --plain-http
```

Register either published recipe in a Recipe Pack and attach it to the test
Environment. Deploy a `Radius.Messaging/kafka@2025-08-01-preview` resource with
`topic: 'events'`. From a separate Pod using `apache/kafka:3.9.1`, use
`/opt/kafka/bin/kafka-console-producer.sh` and
`/opt/kafka/bin/kafka-console-consumer.sh` with `--bootstrap-server <host>:9092`
and `--topic events` to send and read a unique message. Replace the broker Pod,
then read the message again with a new consumer group to check persistence.
Repeat deployment without changes to check idempotence. Delete the Radius
resource and check that its Deployment, Service, and PVC are removed.

## Using the resource type

Add a `kafka` resource to your application and connect a container to it. With Radius control-plane support from `radius-project/radius#12709` and Kubernetes Container Recipe support from `resource-types-contrib#300` or later, one connection named `kafka` injects the ordinary `CONNECTION_KAFKA_HOST` value plus the secret-backed `CONNECTION_KAFKA_CONNECTIONSTRING`. No second managed-Secret connection is needed on compatible Kubernetes versions. For custom or backward-compatible Kubernetes configuration, `kafka.properties.secrets.name` remains available as the `secretName` for an explicitly authored `secretKeyRef`. See [`test/app.bicep`](test/app.bicep) for the gradual-adoption example.
