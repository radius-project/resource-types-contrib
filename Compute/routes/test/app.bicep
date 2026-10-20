extension radius

@description('The ID of the Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Application name. CI supplies a unique name for deployment and cleanup.')
param applicationName string = 'routes-test'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

resource backend 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'backend'
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
      }
    }
  }
}

resource route 'Radius.Compute/routes@2025-08-01-preview' = {
  name: 'testroute'
  properties: {
    environment: environment
    application: app.id
    kind: 'HTTP'
    hostnames: [
      'test.radius.local'
    ]
    rules: [
      {
        matches: [
          {
            httpPath: '/'
          }
        ]
        destinationContainer: {
          resourceId: backend.id
          containerName: 'web'
          containerPort: backend.properties.containers.web.ports.http.containerPort
        }
      }
    ]
  }
}
