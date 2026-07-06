// Platform-engineer baseline for verifying Radius.Data/sqlServerDatabases on Azure via
// a STANDARD Azure Verified Module (AVM) — no Radius wrapper recipe. Radius
// resolves {{context.*}} expressions in `parameters`, runs the AVM through the
// Bicep driver + deployment engine, and maps plain module outputs onto resource
// properties via `outputs`.
//
// Credentials: the developer authors the administrator `username` and `password`
// directly on the sqlServerDatabases resource (app.bicep). `password` is marked
// `x-radius-sensitive`, so Radius encrypts it at rest, redacts it on reads, and
// exposes it decrypted only to this recipe as
// {{context.resource.properties.username/password}}, wired onto the AVM's
// administratorLogin/administratorLoginPassword below.
//
// Portability: this schema is platform-neutral. For AWS RDS SQL Server, a
// Terraform recipe would map `host` from the DB instance endpoint/address and pass
// the same username/password through. For Kubernetes, a recipe could deploy an mssql
// container or StatefulSet, expose it with a Service DNS name for `host`, and set
// `port` to 1433.

extension radius

@description('Azure subscription ID the environment provisions resources into.')
param azureSubscriptionId string

@description('Azure resource group the environment provisions resources into. Must already exist.')
param azureResourceGroup string

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'sqlserver-azure-avm'
  properties: {
    recipes: {
      'Radius.Data/sqlServerDatabases': {
        kind: 'bicep'
        // Standard Azure Verified Module, version pinned with `:<tag>`
        // (https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/sql/server).
        source: 'mcr.microsoft.com/bicep/avm/res/sql/server:0.21.4'
        parameters: {
          name: '{{context.resource.name}}'
          administratorLogin: '{{context.resource.properties.username}}'
          administratorLoginPassword: '{{context.resource.properties.password}}'
          publicNetworkAccess: 'Enabled'
          firewallRules: [
            {
              name: 'AllowAllWindowsAzureIps'
              startIpAddress: '0.0.0.0'
              endIpAddress: '0.0.0.0'
            }
          ]
          databases: [
            {
              name: '{{context.resource.properties.database}}'
              availabilityZone: -1
              sku: {
                name: 'Basic'
                tier: 'Basic'
              }
              maxSizeBytes: 2147483648
              zoneRedundant: false
            }
          ]
          enableTelemetry: false
        }
        // Map the module's FQDN output onto the resource's `host` property. The
        // AVM has no port output; Azure SQL Database uses the fixed TCP port 1433.
        outputs: {
          host: 'fullyQualifiedDomainName'
        }
      }
      // Radius.Compute/containers is a default type but needs a recipe to deploy.
      // The published Kubernetes container recipe materializes the golang-migrate
      // client (which connects to the Azure SQL database) as a Kubernetes Deployment.
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
