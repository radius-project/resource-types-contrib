extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'rabbitmq-azure-test'
  properties: {
    environment: environment
  }
}

resource queue 'Radius.Messaging/rabbitMQ@2025-08-01-preview' = {
  name: 'rabbitmq'
  properties: {
    environment: environment
    application: app.id
    queue: 'jobs'
    username: 'radius'
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
        // The Recipe-generated fallback password is read from the managed
        // Radius.Security/secrets resource via secretKeyRef.
        env: {
          RABBITMQ_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: queue.properties.secrets.name
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
