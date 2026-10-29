extension radius
extension secretStores

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Application name. CI supplies a unique name for deployment and cleanup.')
param applicationName string = 'dapr-secretstores-test'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

// The Kubernetes Secret Recipe creates a Kubernetes secret with the resource name.
resource allowedSecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'dapr-allowed-secret'
  properties: {
    environment: environment
    application: app.id
    data: {
      token: {
        value: 'dapr-allowed-value'
      }
    }
  }
}

resource deniedSecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'dapr-denied-secret'
  properties: {
    environment: environment
    application: app.id
    data: {
      token: {
        value: 'dapr-denied-value'
      }
    }
  }
}

// No componentType is set, so the Recipe deploys a secretstores.kubernetes
// component. Only the allowed client app ID can load the component. The test
// runner gives the default ServiceAccount read access to the allowed secret only.
resource secretStore 'Radius.Dapr/secretStores@2025-08-01-preview' = {
  name: 'secretstore'
  properties: {
    environment: environment
    application: app.id
    scopes: [
      'dapr-secret-client'
    ]
  }
}

// Ready only after it reads the allowed secret and Kubernetes denies the other secret.
resource allowedClient 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'daprsecretclient'
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
        env: {
          ROLE: {
            value: 'allowed'
          }
          ALLOWED_SECRET: {
            value: allowedSecret.name
          }
          DENIED_SECRET: {
            value: deniedSecret.name
          }
        }
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
      secretstore: {
        source: secretStore.id
      }
    }
    extensions: {
      daprSidecar: {
        appId: 'dapr-secret-client'
      }
    }
  }
}

// Ready only after Dapr denies the secret store to this app ID. It has the same
// connection as the allowed client, but its app ID is not in the scopes.
resource deniedClient 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'daprsecretdenied'
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
        env: {
          ROLE: {
            value: 'denied'
          }
          ALLOWED_SECRET: {
            value: allowedSecret.name
          }
          DENIED_SECRET: {
            value: deniedSecret.name
          }
        }
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
      secretstore: {
        source: secretStore.id
      }
    }
    extensions: {
      daprSidecar: {
        appId: 'dapr-secret-denied'
      }
    }
  }
}
