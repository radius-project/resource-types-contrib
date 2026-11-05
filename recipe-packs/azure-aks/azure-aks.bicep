extension radius

@description('Name of the Kubernetes Gateway resource that Radius.Compute/routes attach to. Must already exist in the cluster.')
param routesGatewayName string

@description('Namespace where the Kubernetes Gateway resource for Radius.Compute/routes is located.')
param routesGatewayNamespace string = 'default'

@description('Registry path (e.g. ghcr.io/my-org) that Radius.Compute/containerImages pushes built images to.')
param containerImagesRegistry string

@description('Name of the Kubernetes Secret holding registry credentials for Radius.Compute/containerImages. Leave empty for an unauthenticated registry.')
param containerImagesRegistrySecretName string = ''

@description('Operator PostgreSQL settings in AVM name, source, value form. These override application serverSettings, extensions, and tls without regard to name case. An azure.extensions entry replaces the application allow-list; a require_secure_transport entry pins the transport policy. The port stays fixed at 5432. Defaults to no operator overrides. See recipe-packs/azure-aks/README.md.')
param postgreSqlServerConfigurations array = []

resource azureAksRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aks'
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
            accessKey: 'primaryAccessKey'
            url: 'primaryConnectionString'
          }
        }
      }
      'Radius.AI/models': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-recipes/models:latest'
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
      'Radius.Data/mySqlDatabases': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/db-for-my-sql/flexible-server:0.10.3'
        parameters: {
          name: 'mysql-{{context.azure.resourceNameHash}}'
          administratorLogin: '{{context.resource.properties.username}}'
          administratorLoginPassword: '{{context.resource.properties.password}}'
          skuName: 'Standard_B1ms'
          tier: 'Burstable'
          version: '{{context.resource.properties.version == "5.7" ? "5.7" : context.resource.properties.version == "8.0" ? "8.0.21" : "8.4"}}'
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
          configurations: [
            {
              name: 'require_secure_transport'
              source: 'user-override'
              value: '{{context.resource.properties.tls == "optional" ? "OFF" : "ON"}}'
            }
          ]
          enableTelemetry: false
          lock: {
            kind: 'None'
          }
        }
        outputs: {
          host: 'fqdn'
        }
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-aks-recipes/postgresqldatabases:latest'
        parameters: {
          name: 'pgsql-{{context.azure.resourceNameHash}}'
          configurations: postgreSqlServerConfigurations
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
