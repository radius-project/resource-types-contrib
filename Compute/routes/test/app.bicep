extension radius
extension routes

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'routes-app'
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

resource myRoutes 'Radius.Compute/routes@2025-08-01-preview' = {
  name: 'myRoutes'
  properties: {
    environment: environment
    application: app.id
    hostname: 'myroutes.example.com'
    routes: [
      {
        path: '/api'
        nextHopType: 'VirtualAppliance'
        serviceName: 'api-service'
        port: 8080
      }
      {
        path: '/blocked'
        nextHopType: 'None'
      }
      {
        path: '/external'
        nextHopType: 'Internet'
        nextHopAddress: 'external-service.com'
      }
    ]
  }
}
