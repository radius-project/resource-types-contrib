extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('The broker password. Passed to rad deploy as a secure parameter and stored in a Radius.Security/secrets resource.')
@secure()
param password string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'rabbitmq-azure-test'
  properties: {
    environment: environment
  }
}

// The broker password is supplied via a Radius.Security/secrets resource and its ID
// is passed on the rabbitMQ `password` property. When `password` is omitted, the
// Recipe instead generates a random fallback and returns it through the resource's
// own managed Radius.Security/secrets resource (queue.properties.secrets).
resource rabbitmqSecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'rabbitmq-credentials'
  properties: {
    environment: environment
    application: app.id
    data: {
      password: {
        value: password
      }
    }
  }
}

resource queue 'Radius.Messaging/rabbitMQ@2025-08-01-preview' = {
  name: 'rabbitmq'
  properties: {
    environment: environment
    application: app.id
    queue: 'jobs'
    username: 'radius'
    password: rabbitmqSecret.id
  }
}

resource democontainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'democontainer'
  properties: {
    environment: environment
    application: app.id
    containers: {
      demo: {
        image: 'ghcr.io/radius-project/samples/demo:latest'
        // The developer-owned password remains explicitly wired for portability.
        env: {
          RABBITMQ_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: rabbitmqSecret.name
                key: 'password'
              }
            }
          }
        }
        ports: {
          web: {
            containerPort: 3000
          }
        }
      }
    }
    connections: {
      // On compatible Kubernetes versions, injects host/port/username. A managed
      // password would also be injected as CONNECTION_RABBITMQ_PASSWORD when omitted.
      rabbitmq: {
        source: queue.id
      }
      // User-authored input Secrets retain direct Secret connections. Because
      // `password` was supplied above, the queue connection has no managed secret.
      credentials: {
        source: rabbitmqSecret.id
      }
    }
  }
}
