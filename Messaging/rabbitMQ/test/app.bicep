extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('The broker password. Passed to rad deploy as a secure parameter, stored in a Radius.Security/secrets resource, and mounted into the broker via secretKeyRef so it is never written into the pod spec.')
@secure()
param password string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'rabbitmq-azure-test'
  properties: {
    environment: environment
  }
}

// The developer supplies the broker password via a Radius.Security/secrets resource
// rather than a plaintext property. The rabbitMQ Recipe references the materialized
// Kubernetes Secret by name and mounts the password via secretKeyRef.
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
        // host/port/username arrive via the connection below as CONNECTION_RABBITMQ_*.
        // The password is read directly from the shared Radius.Security/secrets
        // resource via secretKeyRef, so it never lands on the rabbitMQ resource or
        // its pod spec.
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
