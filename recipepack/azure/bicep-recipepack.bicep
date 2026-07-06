// Platform-engineer baseline for verifying Radius.Messaging/kafka on
// Azure via a STANDARD Azure Verified Module (AVM) — no Radius wrapping, no
// `context` parameter, no `result` output. Using the direct-module feature
// (radius PR #12109) Radius:
//   1. resolves any {{context.*}} expressions in `parameters` against the
//      resource being deployed,
//   2. runs the module through the existing Bicep driver + deployment engine,
//      deploying to the environment's Azure subscription + resource group below
//      with the credentials registered via `rad credential register azure sp`,
//   3. maps the module's plain outputs onto the resource's properties via the
//      `outputs` field (`connectionString` <- `primaryConnectionString`,
//      `host` <- `name`).
//
// The AVM version is pinned with the standard Bicep/OCI `:<tag>` syntax.
//
// Portability: this developer-facing Radius type is intentionally platform-
// neutral. Azure uses the Event Hubs namespace AVM below and maps `host` from the
// namespace `name`; AWS can use an MSK Terraform registry module and map `host`
// from `bootstrap_brokers`; Kubernetes can use a Strimzi/Kafka recipe and map
// `host` from the broker bootstrap Service DNS. The schema and app.bicep stay
// stable while only recipePack `source`, `parameters`, and `outputs` change.
//
// NOTE — API-COMPATIBILITY CAVEAT: Azure Event Hubs exposes a Kafka-compatible
// endpoint but is NOT a full Apache Kafka broker. This verification therefore
// proves provisioning, Radius output mapping, and Azure namespace existence only;
// a real Kafka-client connectivity test is out of scope for this resource-type
// verification because the stock demo container has no Kafka client.

extension radius

@description('Azure subscription ID the environment provisions resources into.')
param azureSubscriptionId string

@description('Azure resource group the environment provisions resources into. Must already exist.')
param azureResourceGroup string

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'kafka-azure-avm'
  properties: {
    recipes: {
      'Radius.Messaging/kafka': {
        kind: 'bicep'
        // Standard Azure Verified Module, version pinned with `:<tag>`
        // (https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/event-hub/namespace).
        source: 'mcr.microsoft.com/bicep/avm/res/event-hub/namespace:0.14.2'
        parameters: {
          name: '{{context.resource.name}}'
          // Azure Event Hubs Kafka protocol support requires Standard tier or higher.
          skuName: 'Standard'
          skuCapacity: 1
          // The AVM defaults disableLocalAuth to TRUE, which turns off SAS-key (local)
          // authentication for the namespace. The connection test's container authenticates
          // over Kafka SASL/PLAIN using the SAS `primaryConnectionString`, so SAS auth MUST
          // stay on. Leaving the default would also blank the RootManageSharedAccessKey keys,
          // so the `primaryConnectionString` output comes back empty. Explicitly enable it.
          disableLocalAuth: false
          // Create the developer-authored topic as an Event Hub in the namespace.
          eventhubs: [
            {
              name: '{{context.resource.properties.topic}}'
            }
          ]
          // AVM modules emit a Microsoft.Resources/deployments telemetry resource
          // the Radius Bicep deployment engine can't process at location "global".
          // Disabling telemetry skips it — the AVM-sanctioned opt-out.
          enableTelemetry: false
        }
        // Map the module's outputs onto the resource's properties.
        // Keys are resource property names; values are module output names.
        // `connectionString` is a SAS secret by nature, so the action asserts the
        // `host` output mapping (the namespace name) as its provisioning check.
        outputs: {
          connectionString: 'primaryConnectionString'
          host: 'name'
        }
      }
      // Radius.Compute/containers is a default type but needs a recipe to deploy.
      // The published Kubernetes container recipe materializes the Kafbat Kafka UI
      // client (which connects to the Event Hubs Kafka endpoint over SASL_SSL) as a
      // Kubernetes Deployment and wires the `connections` to the kafka resource.
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
