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
      readinessProbe:{
        kind:'httpGet'
        containerPort:3000
        path: '/order'
        initialDelaySeconds:3
        failureThreshold:4
        periodSeconds:20
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

// The Dapr state store that is connected to the backend container
resource stateStore 'Radius.Dapr/stateStores@2025-11-01-preview' = {
  name: 'stateStore-${uniqueString(application)}'
  properties: {
    // Provision Redis Dapr state store automatically via the default Radius Recipe
    environment: environment
    application: application
  }
}
