// Platform-engineer baseline for verifying Radius.AI/search on Azure via a
// STANDARD Azure Verified Module (AVM) — no Radius wrapping, no `context`
// parameter, no `result` output. Using the direct-module feature, Radius resolves
// recipe parameters, deploys the AVM module to the environment's Azure scope, and
// maps plain module outputs onto the resource properties via the `outputs` field.
//
// Portability: the Radius.AI/search schema is intentionally
// platform-neutral. An AWS recipe could target a Terraform AWS OpenSearch module
// and map `endpoint` from the domain endpoint output; a Kubernetes recipe could
// target an Elasticsearch recipe and map `endpoint` from the service DNS plus
// `apiKey` from a generated secret. Only recipePack `source`, `parameters`, and
// `outputs` change while the developer-facing resource stays the same.
//
// NOTE: This Azure recipe has an API-compatibility caveat. Elasticsearch/OpenSearch
// and Azure AI Search do not share the same query API, so a portable application
// must target a common abstraction or use platform-specific client logic.
//
// The AVM version is pinned with the standard Bicep/OCI `:<tag>` syntax.

extension radius

@description('Azure subscription ID the environment provisions resources into.')
param azureSubscriptionId string

@description('Azure resource group the environment provisions resources into. Must already exist.')
param azureResourceGroup string

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'search-azure-avm'
  properties: {
    recipes: {
      'Radius.AI/search': {
        kind: 'bicep'
        // Standard Azure Verified Module, version pinned with `:<tag>`
        // (https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/search/search-service).
        source: 'mcr.microsoft.com/bicep/avm/res/search/search-service:0.12.2'
        parameters: {
          name: '{{context.resource.name}}'
          sku: 'basic'
          disableLocalAuth: false
          replicaCount: 1
          partitionCount: 1
          // AVM modules emit a Microsoft.Resources/deployments telemetry resource
          // the Radius Bicep deployment engine can't process at location "global".
          // Disabling telemetry skips it — the AVM-sanctioned opt-out.
          enableTelemetry: false
        }
        // Map the module's outputs onto the resource's properties.
        // Keys are resource property names; values are module output names.
        // The endpoint comes from the AVM `endpoint` output and apiKey comes from
        // the secure AVM `primaryKey` output, which calls listAdminKeys().primaryKey
        // when disableLocalAuth is false.
        outputs: {
          endpoint: 'endpoint'
          apiKey: 'primaryKey'
        }
      }
      // Radius.Compute/containers is a default type but needs a recipe to deploy.
      // The published Kubernetes container recipe materializes the hurl client (which
      // drives an Azure AI Search REST round-trip) as a Kubernetes Deployment and wires
      // the `connections` to the search resource.
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
