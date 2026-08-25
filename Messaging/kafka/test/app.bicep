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
        ports: {
          web: {
            containerPort: 3000
          }
        }
      }
    }
    connections: {
      // On compatible Kubernetes versions, injects host plus secret-backed
      // CONNECTION_KAFKA_CONNECTIONSTRING. Explicit env wiring remains supported.
      kafka: {
        source: kafkaBroker.id
      }
    }
  }
}
