// Platform-engineer baseline for verifying Radius.Data/mongoDatabases on Azure via
// a STANDARD Azure Verified Module (AVM) — no Radius wrapping, no `context`
// parameter, no `result` output. Using the direct-module feature Radius:
//   1. resolves any {{context.*}} expressions in `parameters` against the
//      resource being deployed,
//   2. runs the module through the existing Bicep driver + deployment engine,
//      deploying to the environment's Azure subscription + resource group below
//      with the credentials registered via `rad credential register azure sp`,
//   3. maps the module's plain outputs onto the resource's properties via the
//      `outputs` field (`endpoint` <- `endpoint`, `connectionString` <-
//      `primaryReadWriteConnectionString`).
//
// The AVM version is pinned with the standard Bicep/OCI `:<tag>` syntax. Cosmos
// DB for MongoDB provisioning is slow (commonly 10-15 minutes), so the manual E2E
// workflow can take noticeably longer than lighter Azure resource tests.
//
// The recipe pack also registers a Radius.Compute/containers recipe so the
// developer app (app.bicep) can run a real container that connects to MongoDB,
// proving the end-to-end app -> Cosmos DB Mongo API data path — not just that the
// account and database were provisioned.
//
// Portability: the type schema is platform-neutral. An AWS DocumentDB Terraform
// recipe would map the same `endpoint` property from the cluster endpoint and
// surface the master connection secret as `connectionString`; a Kubernetes Mongo
// recipe would map `endpoint` from the service DNS host/port and
// `connectionString` from a generated or referenced Secret. Only recipe source,
// parameters, and output mappings change; application Bicep stays the same.

extension radius

@description('Azure subscription ID the environment provisions resources into.')
param azureSubscriptionId string

@description('Azure resource group the environment provisions resources into. Must already exist.')
param azureResourceGroup string

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'mongodb-azure-avm'
  properties: {
    recipes: {
      'Radius.Data/mongoDatabases': {
        kind: 'bicep'
        // Standard Azure Verified Module, version pinned with `:<tag>`
        // (https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/document-db/database-account).
        source: 'mcr.microsoft.com/bicep/avm/res/document-db/database-account:0.19.0'
        parameters: {
          name: '{{context.resource.name}}'
          capabilitiesToAdd: [
            'EnableMongo'
          ]
          mongodbDatabases: [
            {
              name: '{{context.resource.properties.database}}'
            }
          ]
          // AVM modules emit a Microsoft.Resources/deployments telemetry resource
          // the Radius Bicep deployment engine can't process at location "global".
          // Disabling telemetry skips it — the AVM-sanctioned opt-out.
          enableTelemetry: false
        }
        // Map the module's outputs onto the resource's properties.
        // Keys are resource property names; values are module output names. app.bicep's
        // container reads `endpoint` and `connectionString` directly off the resource.
        outputs: {
          endpoint: 'endpoint'
          connectionString: 'primaryReadWriteConnectionString'
        }
      }
      // Radius.Compute/containers is an auto-registered default type but needs a
      // recipe to deploy. Use resource-types-contrib's published Kubernetes container
      // recipe: it materializes the container (app.bicep `mectr`) as a Kubernetes
      // Deployment to prove the app -> Mongo data path.
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
      // context.runtime.kubernetes.namespace. The 2025-08-01 environment API sources
      // that namespace from providers.kubernetes.namespace; `default` always exists
      // in the kind cluster.
      kubernetes: {
        namespace: 'default'
      }
    }
    recipePacks: [
      recipes.id
    ]
  }
}
