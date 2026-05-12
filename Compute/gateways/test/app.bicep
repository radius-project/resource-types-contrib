extension radius
extension gateways

param environment string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'gateways-testapp'
  properties: {
    environment: environment
  }
}

resource gateway 'Radius.Compute/gateways@2025-08-01-preview' = {
  name: 'web'
  properties: {
    environment: environment
    application: app.id
    gatewayClassName: 'nginx'
    listeners: [
      {
        name: 'http'
        protocol: 'HTTP'
        port: 80
        allowedRoutesFrom: 'All'
      }
    ]
  }
}
