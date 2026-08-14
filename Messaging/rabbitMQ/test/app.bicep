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

resource demoImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'rabbitmq-demo-image'
  properties: {
    environment: environment
    application: app.id
    tag: 'demo-e2e'
    build: {
      source: 'git::https://github.com/radius-project/samples.git//samples/demo?ref=190d9c4c84278980d9fae402330bd5ead76b31a5'
    }
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
        // host/port/username arrive via the connection below as CONNECTION_RABBITMQ_*.
        // The password is read from the same Radius.Security/secrets resource that
        // was passed to the broker via secretKeyRef.
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
      rabbitmq: {
        source: queue.id
      }
    }
  }
}
