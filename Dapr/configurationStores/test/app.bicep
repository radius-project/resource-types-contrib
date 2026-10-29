extension radius
extension configurationStores

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Application name. CI supplies a unique name for deployment and cleanup.')
param applicationName string = 'dapr-configurationstores-test'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

// No componentType is set, so the Recipe deploys Redis and a configuration.redis
// component. Only the client app ID can load the component.
resource configStore 'Radius.Dapr/configurationStores@2025-08-01-preview' = {
  name: 'configstore'
  properties: {
    environment: environment
    application: app.id
    scopes: [
      'dapr-config-client'
    ]
  }
}

// The client becomes ready only after it reads the value that the test runner
// writes to the Recipe-owned Redis.
resource configClient 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'daprconfigclient'
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
      configstore: {
        source: configStore.id
      }
    }
    extensions: {
      daprSidecar: {
        appId: 'dapr-config-client'
      }
    }
  }
}
