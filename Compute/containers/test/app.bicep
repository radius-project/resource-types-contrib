extension radius
extension containers
extension secrets

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'containers-testapp'
  location: 'global'
  properties: {
    environment: environment
    extensions: [
      {
        kind: 'kubernetesNamespace'
        namespace: 'containers-testapp'
      }
    ]
  }
}

// Create a secret
resource mySecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'app-secrets'
  properties: {
    environment: environment
    application: app.id
    data: {
      API_KEY: { value: 'secret-key' }
      DB_PASSWORD: { value: 'password123' }
    }
  }
}

// Create a container that uses the secret
resource myContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'myapp'
  properties: {
    environment: environment
    application: app.id
    containers: {
      web: {
        image: 'nginx:alpine'
        ports: {
          http: {
            containerPort: 80
          }
        }
        resources: {
          requests: {
            cpu: '100m'       
            memoryInMib: 128   
          }
        }
      }
    }
    connections: {
      secrets: {
        source: mySecret.id
      }
    }
    replicas: 1
    autoScaling: {
      maxReplicas: 3
      metrics: [
        {
          kind: 'cpu'
          target: {
            averageUtilization: 50
          }
        }
      ]
    }
  }
}
