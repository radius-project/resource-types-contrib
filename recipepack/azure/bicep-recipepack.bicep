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
        source: 'mcr.microsoft.com/bicep/avm/res/cache/redis-enterprise:0.5.1'
        parameters: {
          name: '{{context.resource.name}}'
          skuName: '{{context.resource.properties.size == "S" ? "Balanced_B0" : "Balanced_B1"}}'
          highAvailability: 'Disabled'
          database: {
            name: 'default'
            accessKeysAuthentication: 'Enabled'
          }
          publicNetworkAccess: 'Enabled'
          enableTelemetry: false
        }
        outputs: {
          host: 'hostName'
          port: 'port'
          url: 'primaryConnectionString'
        }
      }
      'Radius.AI/models': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/cognitive-services/account:0.15.0'
        parameters: {
          name: '{{context.resource.name}}'
          kind: 'OpenAI'
          sku: 'S0'
          customSubDomainName: '{{context.resource.name}}'
          disableLocalAuth: false
          publicNetworkAccess: 'Enabled'
          deployments: [
            {
              name: 'chat'
              model: {
                format: 'OpenAI'
                name: '{{context.resource.properties.model}}'
                version: '2025-08-07'
              }
              sku: {
                name: 'GlobalStandard'
                capacity: 1
              }
            }
          ]
          enableTelemetry: false
        }
        outputs: {
          endpoint: 'endpoint'
          apiKey: 'primaryKey'
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
