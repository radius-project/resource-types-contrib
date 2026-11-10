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

// No componentType is set, so the Recipe deploys Redis and a state.redis
// component. Only the client app ID can load the component.
resource stateStore 'Radius.Dapr/stateStores@2025-08-01-preview' = {
  name: 'statestore'
  properties: {
    environment: environment
    application: app.id
    scopes: [
      'dapr-state-client'
    ]
  }
}

// The client becomes ready only after it writes and reads a value through Dapr.
resource stateClient 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'daprstateclient'
  properties: {
    environment: environment
    application: app.id
    containers: {
      client: {
        image: 'python:3.13-alpine'
        command: [
          'python'
          '-u'
          '-c'
        ]
        args: [
          loadTextContent('dapr-client.py')
        ]
        readinessProbe: {
          exec: {
            command: [
              '/bin/sh'
              '-c'
              'test -f /tmp/dapr-ready'
            ]
          }
          periodSeconds: 2
          timeoutSeconds: 5
          failureThreshold: 150
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
        appId: 'dapr-state-client'
      }
    }
  }
}
