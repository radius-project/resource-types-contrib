extension radius
extension pubSubBrokers

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Application name. CI supplies a unique name for deployment and cleanup.')
param applicationName string = 'dapr-pubsubbrokers-test'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

// No type is set, so the Recipe deploys Redis and a pubsub.redis component.
resource pubSub 'Radius.Dapr/pubSubBrokers@2025-08-01-preview' = {
  name: 'pubsub'
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
      pubsub: {
        source: pubSub.id
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
