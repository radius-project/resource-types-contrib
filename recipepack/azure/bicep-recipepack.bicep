extension radius

@description('Azure subscription ID the environment provisions resources into.')
param azureSubscriptionId string

@description('Azure resource group the environment provisions resources into. Must already exist.')
param azureResourceGroup string

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'mysql-azure-avm'
  properties: {
    recipes: {
      'Radius.Data/mySqlDatabases': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/db-for-my-sql/flexible-server:0.10.3'
        parameters: {
          name: '{{context.resource.name}}'
          // Administrator credentials come directly from the developer-authored
          // resource properties. `password` is x-radius-sensitive, so Radius exposes
          // it decrypted to the recipe as {{context.resource.properties.password}}.
          administratorLogin: '{{context.resource.properties.username}}'
          administratorLoginPassword: '{{context.resource.properties.password}}'
          // Cheapest Burstable SKU keeps provisioning quick and inexpensive.
          skuName: 'Standard_B1ms'
          tier: 'Burstable'
          // Map the developer-authored `version` enum (5.7|8.0|8.4) onto a concrete
          // MySQL server version. Azure MySQL flexible server supports 5.7 and
          // 8.0.21, so anything other than 5.7 maps to 8.0.21.
          version: '{{context.resource.properties.version == "5.7" ? "5.7" : "8.0.21"}}'
          // Create the developer-authored database on the server.
          databases: [
            {
              name: '{{context.resource.properties.database}}'
            }
          ]
          // -1 = no hardcoded availability zone (required by the AVM).
          availabilityZone: -1
          // Burstable tier supports neither zone-redundant HA nor geo-redundant
          // backup; both AVM defaults must be turned off.
          highAvailability: 'Disabled'
          geoRedundantBackup: 'Disabled'
          storageSizeGB: 32
          publicNetworkAccess: 'Enabled'
          enableTelemetry: false
        }
        // Map the module's outputs onto the resource's properties. The AVM has no
        // port output (MySQL flexible server is always 3306), so only `host` is
        // mapped here, from the module's `fqdn` output.
        outputs: {
          host: 'fqdn'
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
      kubernetes: {
        namespace: 'default'
      }
    }
    recipePacks: [
      recipes.id
    ]
  }
}
