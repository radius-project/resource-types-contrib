extension radius
extension stateStores

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Application name. CI supplies a unique name for deployment and cleanup.')
param applicationName string = 'dapr-statestores-test'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

// No componentType is set, so the Recipe deploys Redis and a state.redis component.
resource stateStore 'Radius.Dapr/stateStores@2025-08-01-preview' = {
  name: 'statestore'
  properties: {
    environment: environment
    application: app.id
  }
}

resource backend 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'backend'
  properties: {
    environment: environment
    application: app.id
    containers: {
      backend: {
        image: 'ghcr.io/radius-project/samples/demo:latest'
        ports: {
          web: {
            containerPort: 3000
          }
        }
      }
    }
    connections: {
      statestore: {
        source: stateStore.id
      }
    }
    extensions: {
      daprSidecar: {
        appId: 'backend'
        appPort: 3000
      }
    }
  }
}
