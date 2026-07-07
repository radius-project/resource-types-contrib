extension radius

@description('Azure subscription ID the environment provisions resources into.')
param azureSubscriptionId string

@description('Azure resource group the environment provisions resources into. Must already exist.')
param azureResourceGroup string

@description('Name of the Kubernetes Gateway resource that Radius.Compute/routes attach to. Must already exist in the cluster.')
param routesGatewayName string

@description('Namespace where the Kubernetes Gateway resource for Radius.Compute/routes is located.')
param routesGatewayNamespace string = 'default'

@description('Registry path (e.g. ghcr.io/my-org) that Radius.Compute/containerImages pushes built images to.')
param containerImagesRegistry string

@description('Name of the Kubernetes Secret holding registry credentials for Radius.Compute/containerImages. Leave empty for an unauthenticated registry.')
param containerImagesRegistrySecretName string = ''

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-avm'
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
      'Radius.AI/search': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/search/search-service:0.12.2'
        parameters: {
          name: '{{context.resource.name}}'
          sku: 'basic'
          disableLocalAuth: false
          replicaCount: 1
          partitionCount: 1
          enableTelemetry: false
        }
        outputs: {
          endpoint: 'endpoint'
          apiKey: 'primaryKey'
        }
      }
      'Radius.Data/mongoDatabases': {
        kind: 'bicep'
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
          networkRestrictions: {
            ipRules: []
            publicNetworkAccess: 'Enabled'
          }
          enableTelemetry: false
        }
        outputs: {
          endpoint: 'endpoint'
          connectionString: 'primaryReadWriteConnectionString'
        }
      }
      'Radius.Data/mySqlDatabases': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/db-for-my-sql/flexible-server:0.10.3'
        parameters: {
          name: '{{context.resource.name}}'
          administratorLogin: '{{context.resource.properties.username}}'
          administratorLoginPassword: '{{context.resource.properties.password}}'
          skuName: 'Standard_B1ms'
          tier: 'Burstable'
          version: '{{context.resource.properties.version == "5.7" ? "5.7" : "8.0.21"}}'
          databases: [
            {
              name: '{{context.resource.properties.database}}'
            }
          ]
          availabilityZone: -1
          highAvailability: 'Disabled'
          geoRedundantBackup: 'Disabled'
          storageSizeGB: 32
          publicNetworkAccess: 'Enabled'
          firewallRules: [
            {
              name: 'allow-all'
              startIpAddress: '0.0.0.0'
              endIpAddress: '255.255.255.255'
            }
          ]
          enableTelemetry: false
        }
        outputs: {
          host: 'fqdn'
        }
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/db-for-postgre-sql/flexible-server:0.15.2'
        parameters: {
          name: '{{context.resource.name}}'
          administratorLogin: '{{context.resource.properties.username}}'
          administratorLoginPassword: '{{context.resource.properties.password}}'
          authConfig: {
            activeDirectoryAuth: 'Enabled'
            passwordAuth: 'Enabled'
          }
          skuName: '{{context.resource.properties.size == "S" ? "Standard_B1ms" : "Standard_D2ds_v5"}}'
          tier: '{{context.resource.properties.size == "S" ? "Burstable" : "GeneralPurpose"}}'
          databases: [
            {
              name: '{{context.resource.properties.database}}'
            }
          ]
          version: '16'
          availabilityZone: -1
          highAvailability: 'Disabled'
          geoRedundantBackup: 'Disabled'
          storageSizeGB: 32
          publicNetworkAccess: 'Enabled'
          firewallRules: [
            {
              name: 'allow-all'
              startIpAddress: '0.0.0.0'
              endIpAddress: '255.255.255.255'
            }
          ]
          enableAdvancedThreatProtection: false
          enableTelemetry: false
        }
        outputs: {
          host: 'fqdn'
        }
      }
      'Radius.Data/sqlServerDatabases': {
        kind: 'bicep'
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
        outputs: {
          host: 'fullyQualifiedDomainName'
        }
      }
      'Radius.Messaging/rabbitMQ': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/service-bus/namespace:0.16.2'
        parameters: {
          name: '{{context.resource.name}}'
          skuObject: {
            name: 'Standard'
          }
          zoneRedundant: false
          disableLocalAuth: false
          queues: [
            {
              name: '{{context.resource.properties.queue}}'
            }
          ]
          enableTelemetry: false
        }
        outputs: {
          host: 'name'
          connectionString: 'primaryConnectionString'
        }
      }
      'Radius.Messaging/kafka': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/event-hub/namespace:0.14.2'
        parameters: {
          name: '{{context.resource.name}}'
          skuName: 'Standard'
          skuCapacity: 1
          disableLocalAuth: false
          eventhubs: [
            {
              name: '{{context.resource.properties.topic}}'
            }
          ]
          enableTelemetry: false
        }
        outputs: {
          host: 'name'
          connectionString: 'primaryConnectionString'
        }
      }
      'Radius.Storage/objectStorage': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/storage/storage-account:0.32.1'
        parameters: {
          name: '{{context.resource.name}}'
          kind: 'StorageV2'
          skuName: 'Standard_LRS'
          allowBlobPublicAccess: false
          // The AVM storage-account module is secure-by-default: with no networkAcls
          // it applies { bypass: 'AzureServices', defaultAction: 'Deny' }, which
          // firewalls the blob data plane so connecting apps get 403
          // AuthorizationFailure. Allow key-authenticated data-plane access; data
          // stays private (allowBlobPublicAccess is false and access needs the key).
          networkAcls: {
            bypass: 'AzureServices'
            defaultAction: 'Allow'
          }
          blobServices: {
            containers: [
              {
                name: '{{context.resource.properties.containerName}}'
              }
            ]
          }
          enableTelemetry: false
        }
        outputs: {
          endpoint: 'primaryBlobEndpoint'
          accountKey: 'primaryAccessKey'
          accountName: 'name'
        }
      }
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containers:latest'
      }
      'Radius.Compute/persistentVolumes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/persistentvolumes:latest'
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/secrets:latest'
      }
      'Radius.Compute/routes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/routes:latest'
        parameters: {
          gatewayName: routesGatewayName
          gatewayNamespace: routesGatewayNamespace
        }
      }
      'Radius.Compute/containerImages': {
        kind: 'terraform'
        source: 'git::https://github.com/radius-project/resource-types-contrib.git//Compute/containerImages/recipes/kubernetes/terraform'
        parameters: {
          registry: containerImagesRegistry
          registrySecretName: containerImagesRegistrySecretName
        }
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
