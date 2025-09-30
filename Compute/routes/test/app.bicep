extension radius
extension containers
extension routes

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'routes-example-app'
  location: 'global'
  properties: {
    environment: environment
    extensions: [
      {
        kind: 'kubernetesNamespace'
        namespace: 'routes-example'
      }
    ]
  }
}

resource myContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'myContainer'
  properties: {
    environment: environment
    application: app.id
    containers: {
      frontend: {
        image: 'nginx:latest'
        ports: {
          web: {
            containerPort: 80
          }
        }
      }
      accounts: {
        image: 'nginx:latest'
        ports: {
          web: {
            containerPort: 80
          }
        }
      }
    }
  }
}

resource gatewayRule 'Radius.Compute/routes@2025-08-01-preview' = {
  name: 'gatewayRule'
  properties: {
    environment: environment
    application: app.id
    kind: 'HTTP'
    hostnames: ['myapp.example.com']
    rules: [
      {
        matches: [
          {
            httpPath: '/'
          }
        ]
        destinationContainer: {
          resourceId: myContainer.id
          containerName: 'frontend'
          containerPortName: 'web'
        }
      }
      {
        matches: [
          {
            httpPath: '/accounts'
          }
        ]
        destinationContainer: {
          resourceId: myContainer.id
          containerName: 'accounts'
          containerPortName: 'web'
        }
      }
    ]
  }
}
