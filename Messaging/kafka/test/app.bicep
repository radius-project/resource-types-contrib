extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'kafka-azure-test'
  properties: {
    environment: environment
  }
}

resource kafkaBroker 'Radius.Messaging/kafka@2025-08-01-preview' = {
  name: 'kafka'
  properties: {
    environment: environment
    application: app.id
    topic: 'events'
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
        // secretKeyRef — the value never lands on kafkaBroker state.
        env: {
          KAFKA_CONNECTIONSTRING: {
            valueFrom: {
              secretKeyRef: {
                secretName: kafkaBroker.properties.secrets.name
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
      kafka: {
        source: kafkaBroker.id
      }
    }
  }
}
