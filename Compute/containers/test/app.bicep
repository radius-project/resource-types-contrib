extension radius
extension containers

param environment string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'testapp'
  location: 'global'
  properties: {
    environment: environment
  }
}

resource container 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'minimal'
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
