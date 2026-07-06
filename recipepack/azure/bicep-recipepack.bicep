// Platform-engineer baseline for verifying Radius.Data/redisCaches on Azure via a
// STANDARD Azure Verified Module (AVM) — no Radius wrapper recipe. Radius resolves
// {{context.*}} expressions in `parameters`, runs the AVM through the Bicep driver
// + deployment engine, and maps plain module outputs onto resource properties via
// `outputs` (host <- hostName, port <- port, url <- primaryConnectionString).
//
// Credentials: unlike database types, redisCaches needs no injected secret. Azure
// Managed Redis generates its own access keys; the recipe enables access-key
// authentication so the module emits a ready-to-use connection string.
//
// Module choice: this pack uses AZURE MANAGED REDIS (`avm/res/cache/redis-enterprise`),
// NOT classic Azure Cache for Redis (`avm/res/cache/redis`). Classic Azure Cache
// for Redis cannot disable AUTH on a public cache and its AVM module emits no
// access-key/connection-string output (only a Key Vault export), so a connecting
// app can never obtain a credential. Azure Managed Redis (Redis Enterprise,
// `Balanced_*` SKUs) supports access-key auth and its AVM module emits
// `primaryConnectionString` (a ready-to-use `rediss://` URL) mapped onto `url`.
//
// Portability: this schema is platform-neutral. For AWS ElastiCache a Terraform
// recipe would map `host`/`port` from the cluster endpoint and build `url`. For
// Kubernetes a recipe could deploy a redis container/StatefulSet, expose it with a
// Service DNS name for `host`, and set `port` to 6379.

extension radius

@description('Azure subscription ID the environment provisions resources into.')
param azureSubscriptionId string

@description('Azure resource group the environment provisions resources into. Must already exist.')
param azureResourceGroup string

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'redis-azure-avm'
  properties: {
    recipes: {
      'Radius.Data/redisCaches': {
        kind: 'bicep'
        // Standard Azure Verified Module, version pinned with `:<tag>`
        // (https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/cache/redis-enterprise).
        source: 'mcr.microsoft.com/bicep/avm/res/cache/redis-enterprise:0.5.1'
        parameters: {
          name: '{{context.resource.name}}'
          // Map the developer-authored `size` enum (S|M|L) onto a concrete Azure
          // Managed Redis SKU via {{context.*}} parameter expression resolution; the
          // recipe engine resolves these per deployed resource. The resolver
          // currently supports single-level ternaries (radius-project/radius#12238),
          // so M and L collapse to the same (next) SKU. `Balanced_B0` is the
          // smallest Azure Managed Redis SKU.
          skuName: '{{context.resource.properties.size == "S" ? "Balanced_B0" : "Balanced_B1"}}'
          // Single replica — no high-availability replication. Only honoured on
          // Azure Managed Redis SKUs.
          highAvailability: 'Disabled'
          // Create the default database with access-key authentication enabled. This
          // is what makes the module emit `primaryAccessKey`/`primaryConnectionString`
          // (gated on `accessKeysAuthentication == 'Enabled'`), giving a connecting
          // app a credential. Clients connect over TLS (`rediss://`).
          database: {
            name: 'default'
            accessKeysAuthentication: 'Enabled'
          }
          // Public access keeps the pack self-contained (no VNet integration).
          publicNetworkAccess: 'Enabled'
          // AVM modules emit a Microsoft.Resources/deployments telemetry resource
          // the Radius Bicep deployment engine can't process at location "global".
          // Disabling telemetry skips it — the AVM-sanctioned opt-out.
          enableTelemetry: false
        }
        // Map the module's outputs onto the resource's properties.
        //   host <- hostName  (the cluster host, e.g. <name>.<region>.redis.azure.net)
        //   port <- port      (an int; Azure Managed Redis serves on 10000)
        //   url  <- primaryConnectionString  (a ready-to-use `rediss://:<key>@host:10000` TLS URL)
        outputs: {
          host: 'hostName'
          port: 'port'
          url: 'primaryConnectionString'
        }
      }
      // Radius.Compute/containers is a default type but needs a recipe to deploy.
      // The published Kubernetes container recipe materializes the container as a
      // Kubernetes Deployment and turns its `connections` to the redisCaches
      // resource into CONNECTION_REDIS_* environment variables (host/port/url) the
      // app reads to connect.
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
      kubernetes: {
        namespace: 'default'
      }
    }
    recipePacks: [
      recipes.id
    ]
  }
}
