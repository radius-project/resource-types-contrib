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
        // The recipe's secret output(s) are materialized into a managed
        // Radius.Security/secrets resource and consumed here BY REFERENCE via
        // secretKeyRef — the value never lands on queue state.
        env: {
          RABBITMQ_CONNECTIONSTRING: {
            valueFrom: {
              secretKeyRef: {
                secretName: queue.properties.secrets.name
                key: 'connectionString'
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
