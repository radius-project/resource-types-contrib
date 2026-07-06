// Platform-engineer baseline for verifying Radius.Data/postgreSqlDatabases on Azure
// via a STANDARD Azure Verified Module (AVM) using the direct-module feature (radius
// PR #12109). This single environment serves BOTH postgres verification workflows:
//   - the provisioning-only test (tests/postgresql/azure/app.bicep), which deploys the
//     database with no connecting container and leaves clientIpAddress empty, and
//   - the app-to-database connection test (tests/postgresql/<org>-<repo>/app.bicep),
//     which also runs a real container, so the recipe pack registers a
//     Radius.Compute/containers recipe and the connecting workflow passes
//     clientIpAddress to open the flexible-server firewall to the CI runner.
//
// Using the direct-module feature Radius:
//   1. resolves any {{context.*}} expressions in `parameters` against the resource
//      being deployed (including the developer's injected secret values),
//   2. runs the AVM through the Bicep driver + deployment engine, deploying to the
//      environment's Azure subscription + resource group below,
//   3. maps the module's plain outputs onto the resource's properties via `outputs`
//      (the PostgreSQL `host` property <- the module `fqdn`).
//
// Credentials: the developer authors `username` and `password` directly on the
// postgreSqlDatabases resource (app.bicep). `password` is x-radius-sensitive, so Radius
// stores it encrypted, redacts it on reads, and injects it decrypted into the recipe.
// Both are wired onto the AVM's administrator login/password below via
// {{context.resource.properties.username/password}}.

extension radius

@description('Azure subscription ID the environment provisions resources into.')
param azureSubscriptionId string

@description('Azure resource group the environment provisions resources into. Must already exist.')
param azureResourceGroup string

@description('Optional public IP allowed through the flexible server firewall — the CI runner egress IP, which the in-cluster app container also NATs through. The connection-test workflow computes it at provision time; the provisioning-only workflow leaves it empty (no firewall rule is added).')
param clientIpAddress string = ''

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'postgresql-azure-avm'
  properties: {
    recipes: {
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        // Standard Azure Verified Module, version pinned with `:<tag>`
        // (https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/db-for-postgre-sql/flexible-server).
        source: 'mcr.microsoft.com/bicep/avm/res/db-for-postgre-sql/flexible-server:0.15.2'
        parameters: {
          name: '{{context.resource.name}}'
          // Administrator credentials come directly from the resource's `username` and
          // `password` properties (password is x-radius-sensitive; Radius injects it
          // decrypted into the recipe). No credential is hardcoded in this recipe.
          administratorLogin: '{{context.resource.properties.username}}'
          administratorLoginPassword: '{{context.resource.properties.password}}'
          // Enable password auth (the AVM defaults to Entra-only, under which Azure
          // ignores the admin login/password) so the injected USERNAME/PASSWORD are
          // the real SQL admin credentials the container will authenticate with.
          authConfig: {
            activeDirectoryAuth: 'Enabled'
            passwordAuth: 'Enabled'
          }
          // Open the flexible server firewall to the CI runner's egress IP. The app
          // container runs in the in-cluster kind network and NATs out through that
          // same runner IP, and Spring Boot opens its datasource connection EAGERLY at
          // startup — so the rule must already exist when the server is created (before
          // the container starts), not be added by a later verify step. The app
          // connects over TLS (sslmode=require in its JDBC URL), so Azure's default
          // require_secure_transport=ON is left in place. publicNetworkAccess stays
          // Enabled so the public-internet runner IP can reach the server. When
          // clientIpAddress is empty (provisioning-only test, no connecting container)
          // no rule is added.
          firewallRules: empty(clientIpAddress) ? [] : [
            {
              name: 'e2e-runner'
              startIpAddress: clientIpAddress
              endIpAddress: clientIpAddress
            }
          ]
          // Map the developer-authored `size` enum (S|M|L) onto a concrete AVM SKU +
          // tier via {{context.*}} parameter expression resolution. The resolver only
          // supports single-level ternaries today (radius-project/radius#12238), so M
          // and L collapse to the same GeneralPurpose SKU.
          skuName: '{{context.resource.properties.size == "S" ? "Standard_B1ms" : "Standard_D2ds_v5"}}'
          tier: '{{context.resource.properties.size == "S" ? "Burstable" : "GeneralPurpose"}}'
          // Create the developer-authored database (context.resource.properties.database)
          // on the server. The container connects to exactly this database.
          databases: [
            {
              name: '{{context.resource.properties.database}}'
            }
          ]
          version: '16'
          // -1 = no hardcoded availability zone (required by the AVM).
          availabilityZone: -1
          // Burstable tier does not support zone-redundant HA or geo-redundant backup.
          highAvailability: 'Disabled'
          geoRedundantBackup: 'Disabled'
          storageSizeGB: 32
          // Public access (no delegated VNet) keeps the test self-contained; the
          // in-cluster app reaches the server through a runner-IP firewall rule the
          // verify step opens.
          publicNetworkAccess: 'Enabled'
          enableAdvancedThreatProtection: false
          // AVM modules emit a Microsoft.Resources/deployments telemetry resource the
          // Radius Bicep deployment engine can't process at location "global".
          enableTelemetry: false
        }
        // Map the module's `fqdn` output onto the resource's `host` property. The
        // app composes its JDBC URL from this property (postgresql.properties.host in
        // app.bicep). The AVM has no port output (flexible server is always 5432).
        outputs: {
          host: 'fqdn'
        }
      }
      // Radius.Compute/containers is also an auto-registered default type but needs a
      // recipe to deploy. Use resource-types-contrib's published Kubernetes container
      // recipe: it materializes the container as a Kubernetes Deployment, wires the
      // `connections` to the postgreSqlDatabases resource as CONNECTION_POSTGRESQL_*
      // environment variables (host/database from properties), and mounts env vars
      // sourced from the linked secret (the app reads username/password via secretKeyRef).
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
      // The Radius.Security/secrets and Radius.Compute/containers recipes provision
      // Kubernetes resources in context.runtime.kubernetes.namespace. The 2025-08-01
      // environment API sources that namespace from providers.kubernetes.namespace;
      // `default` always exists in the kind cluster.
      kubernetes: {
        namespace: 'default'
      }
    }
    recipePacks: [
      recipes.id
    ]
  }
}
