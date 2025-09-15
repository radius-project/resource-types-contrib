extension radius
extension routes

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'routes-test-app'
  location: 'global'
  properties: {
    environment: environment
    extensions: [
      {
        kind: 'kubernetesNamespace'
        namespace: 'routes-test'
      }
    ]
  }
}

// Simple routes resource with mock container references
resource testRoutes 'Radius.Compute/routes@2025-08-01-preview' = {
  name: 'testRoutes'
  properties: {
    environment: environment
    application: app.id
    kind: 'HTTP'
    hostnames: ['test.local']
    rules: [
      {
        matches: [
          {
            httpPath: '/'
          }
        ]
        destinationContainer: {
          resourceId: '/planes/radius/local/resourceGroups/test-group/providers/Radius.Compute/containers/mock-container'
          containerName: 'mock-web'
          containerPortName: 'http'
        }
      }
      {
        matches: [
          {
            httpPath: '/api'
          }
        ]
        destinationContainer: {
          resourceId: '/planes/radius/local/resourceGroups/test-group/providers/Radius.Compute/containers/mock-container'
          containerName: 'mock-api'
          containerPortName: 'http'
        }
      }
    ]
  }
}
