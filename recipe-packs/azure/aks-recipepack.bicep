extension radius

@description('Name of the Radius environment to create.')
param environmentName string = 'default'

@description('Kubernetes namespace the Radius environment deploys resources into.')
param environmentNamespace string = 'default'

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

@description('Additional PostgreSQL server parameters applied to the flexible server for Radius.Data/postgreSqlDatabases, using the shape with name and value fields. Most commonly used to allow-list extensions via the azure.extensions parameter, for example to enable pgvector. See recipe-packs/azure/README.md for an example and a link to the supported extensions. Defaults to an empty array (no extra server configuration). The server keeps require_secure_transport on, which the Recipe reports through the resource type sslMode property, so do not set that parameter here.')
param postgreSqlServerConfigurations array = []

@description('Additional MySQL server parameters applied to the flexible server for Radius.Data/mySqlDatabases, using the shape with name and value fields. Defaults to an empty array (no extra server configuration). The server keeps require_secure_transport ON, which the Recipe reports through the resource type sslMode property, so do not set that parameter here.')
param mySqlServerConfigurations array = []

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-avm'
  properties: {
    // Globally unique Azure names use the Cloud Adoption Framework resource abbreviation as a prefix, plus a stable hash.
    recipes: {
      'Radius.Data/redisCaches': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/cache/redis-enterprise:0.5.1'
        parameters: {
          name: 'amr-{{context.azure.resourceNameHash}}'
          skuName: '{{context.resource.properties.size == "S" ? "Balanced_B0" : "Balanced_B1"}}'
          highAvailability: 'Disabled'
          database: {
            name: 'default'
            accessKeysAuthentication: 'Enabled'
          }
          publicNetworkAccess: 'Enabled'
          enableTelemetry: false
          lock: {
            kind: 'None'
          }
        }
        outputs: {
          host: 'hostName'
          port: 'port'
          secrets: {
            url: 'primaryConnectionString'
          }
        }
      }
      'Radius.AI/models': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/cognitive-services/account:0.15.0'
        parameters: {
          name: 'oai-{{context.azure.resourceNameHash}}'
          kind: 'OpenAI'
          sku: 'S0'
          customSubDomainName: 'oai-{{context.azure.resourceNameHash}}'
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
          lock: {
            kind: 'None'
          }
        }
        outputs: {
          endpoint: 'endpoint'
          secrets: {
            apiKey: 'primaryKey'
          }
        }
      }
      'Radius.AI/search': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/search/search-service:0.12.2'
        parameters: {
          name: 'srch-{{context.azure.resourceNameHash}}'
          sku: 'basic'
          disableLocalAuth: false
          replicaCount: 1
          partitionCount: 1
          enableTelemetry: false
          lock: {
            kind: 'None'
          }
        }
        outputs: {
          endpoint: 'endpoint'
          secrets: {
            apiKey: 'primaryKey'
          }
        }
      }
      'Radius.Data/mongoDatabases': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/document-db/database-account:0.19.0'
        parameters: {
          name: 'cosmon-{{context.azure.resourceNameHash}}'
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
          lock: {
            kind: 'None'
          }
        }
        outputs: {
          endpoint: 'endpoint'
          secrets: {
            connectionString: 'primaryReadWriteConnectionString'
          }
        }
      }
      // These two types are provisioned by Recipes in this repository rather than
      // by a direct AVM module reference. A direct module can only map outputs the
      // module itself declares, and neither flexible server module declares the
      // transport the provisioned server requires, so the type's sslMode property
      // could not be populated on Azure. See Data/mySqlDatabases/recipes/azure/bicep.
      'Radius.Data/mySqlDatabases': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/azuremysqldatabases:latest'
        parameters: {
          serverConfigurations: mySqlServerConfigurations
        }
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/azurepostgresqldatabases:latest'
        parameters: {
          serverConfigurations: postgreSqlServerConfigurations
        }
      }
      'Radius.Data/sqlServerDatabases': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/sql/server:0.21.4'
        parameters: {
          name: 'sql-{{context.azure.resourceNameHash}}'
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
          lock: {
            kind: 'None'
          }
        }
        outputs: {
          host: 'fullyQualifiedDomainName'
        }
      }
      // Azure has no first-party managed RabbitMQ, and Azure Service Bus speaks
      // AMQP 1.0 (with an `Endpoint=sb://...` connection string) rather than the
      // AMQP 0-9-1 protocol RabbitMQ clients require. So this type deploys an actual
      // RabbitMQ broker container onto the AKS cluster via the Kubernetes recipe,
      // the same way the compute recipes above run on the cluster.
      'Radius.Messaging/rabbitMQ': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/rabbitmq:latest'
      }
      'Radius.Messaging/kafka': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/event-hub/namespace:0.14.2'
        parameters: {
          name: 'evhns-{{context.azure.resourceNameHash}}'
          skuName: 'Standard'
          skuCapacity: 1
          disableLocalAuth: false
          eventhubs: [
            {
              name: '{{context.resource.properties.topic}}'
            }
          ]
          enableTelemetry: false
          lock: {
            kind: 'None'
          }
        }
        outputs: {
          host: 'name'
          secrets: {
            connectionString: 'primaryConnectionString'
          }
        }
      }
      'Radius.Storage/objectStorage': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/storage/storage-account:0.32.1'
        parameters: {
          name: 'st{{context.azure.resourceNameHash}}'
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
          lock: {
            kind: 'None'
          }
        }
        outputs: {
          endpoint: 'primaryBlobEndpoint'
          accountName: 'name'
          secrets: {
            accountKey: 'primaryAccessKey'
            connectionString: 'primaryConnectionString'
          }
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
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containerimages:latest'
        parameters: {
          registry: containerImagesRegistry
          registrySecretName: containerImagesRegistrySecretName
        }
      }
    }
  }
}

resource env 'Radius.Core/environments@2025-08-01-preview' = {
  name: environmentName
  properties: {
    providers: {
      azure: {
        subscriptionId: azureSubscriptionId
        resourceGroupName: azureResourceGroup
      }
      kubernetes: {
        namespace: environmentNamespace
      }
    }
    recipePacks: [
      recipes.id
    ]
  }
}
