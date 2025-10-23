extension radius
extension stateStores

@description('Specifies the environment for resources.')
param environment string

param application string
  
resource backend 'Applications.Core/containers@2023-10-01-preview' = {
  name: 'backend-${uniqueString(application)}'
  properties: {
    application: application
    container: {
      image: 'ghcr.io/radius-project/samples/dapr-backend:latest'
      ports: {
        orders: {
          containerPort: 3000
        }
      }
    }
    connections: {
      orders: {
        source: stateStore.id
      }
    }
    extensions: [
      {
        kind: 'daprSidecar'
        appId: 'backend'
        appPort: 3000
      }
    ]
  }
}
var pgHost = 'postgres-${uniqueString(application)}'
resource postgres 'Applications.Core/containers@2023-10-01-preview' = {
  name: pgHost
  properties: {
    application: application
    container: {
      image: 'postgres:18-alpine'
      ports: {
        postgres: {
          containerPort: 5432
        }
      }
      env: {
        POSTGRES_USER: {
          value: 'dapr'
        }
        POSTGRES_PASSWORD: {
          value: 'password'
        }
        POSTGRES_DB: {
          value: 'daprStore'
        }
      }
    }
  }
}

// The Dapr state store that is connected to the backend container
resource stateStore 'Radius.Dapr/stateStores@2025-11-01-preview' = {
  name: 'backend-${uniqueString(application)}'
  dependsOn: [
    postgres
  ]
  properties: {
    environment: environment
    application: application
    type: 'state.postgresql'
    // This is one of the few components having multiple versions
    version: 'v2'
    metadata: [
      {
        name: 'connectionString'
        value: 'host=${pgHost} user=dapr password=password dbname=daprStore port=5432 sslmode=disable'
      }
    ]
  }
}
