// Platform-engineer baseline for verifying Radius.Messaging/rabbitMQ on
// Azure via a STANDARD Azure Verified Module (AVM) — no Radius wrapping, no
// `context` parameter, no `result` output. Using the direct-module feature,
// Radius resolves {{context.*}} expressions, deploys the AVM to the environment's
// Azure subscription/resource group, and maps plain module outputs back to the
// resource's properties via the `outputs` field.
//
// Portability: this developer-facing type can be implemented with other recipes,
// for example AWS Amazon MQ via Terraform or a Kubernetes RabbitMQ recipe. Only
// the recipePack `source`, `parameters`, and `outputs` mapping should vary across
// platforms; the schema's queue knob and readOnly host/connectionString surface
// stay stable.
//
// NOTE: Azure Service Bus exposes AMQP 1.0 but is not a RabbitMQ broker and does
// not provide RabbitMQ's native AMQP 0-9-1 wire protocol. The warpstreamlabs-bento
// connection test therefore verifies connectivity with a generic AMQP 1.0 client
// (SASL PLAIN over TLS on port 5671) rather than a RabbitMQ-native client, running
// a send/receive round-trip against the provisioned namespace/queue.

extension radius

@description('Azure subscription ID the environment provisions resources into.')
param azureSubscriptionId string

@description('Azure resource group the environment provisions resources into. Must already exist.')
param azureResourceGroup string

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'rabbitmq-azure-avm'
  properties: {
    recipes: {
      'Radius.Messaging/rabbitMQ': {
        kind: 'bicep'
        // Standard Azure Verified Module, version pinned with `:<tag>`
        // (https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/service-bus/namespace).
        source: 'mcr.microsoft.com/bicep/avm/res/service-bus/namespace:0.16.2'
        parameters: {
          name: '{{context.resource.name}}'
          skuObject: {
            name: 'Standard'
          }
          // The module defaults zone redundancy on, which requires Premium; keep
          // this Standard SKU test cheap and valid.
          zoneRedundant: false
          // The module defaults local/SAS auth off. Enable it so the
          // RootManageSharedAccessKey connection string is available and usable.
          disableLocalAuth: false
          queues: [
            {
              name: '{{context.resource.properties.queue}}'
            }
          ]
          // AVM modules emit a Microsoft.Resources/deployments telemetry resource
          // the Radius Bicep deployment engine can't process at location "global".
          // Disabling telemetry skips it — the AVM-sanctioned opt-out.
          enableTelemetry: false
        }
        // Map the module's outputs onto the resource's properties.
        // Keys are resource property names; values are module output names. The
        // sensitive connection string is exposed by the AVM as
        // `primaryConnectionString`, which reads the namespace
        // AuthorizationRules/RootManageSharedAccessKey listKeys result. `host` is
        // intentionally mapped to the namespace `name` output for this verification.
        outputs: {
          host: 'name'
          connectionString: 'primaryConnectionString'
        }
      }
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containers:latest'
      }
    }
  }
}

resource env 'Radius.Core/environments@2025-08-01-preview' = {
  name: 'default'
  properties: {
    providers: {
      azure: {
        subscriptionId: azureSubscriptionId
        resourceGroupName: azureResourceGroup
      }
      // The Radius.Compute/containers recipe provisions a Kubernetes Deployment in
      // providers.kubernetes.namespace; `default` always exists in the kind cluster.
      kubernetes: {
        namespace: 'default'
      }
    }
    recipePacks: [
      recipes.id
    ]
  }
}
