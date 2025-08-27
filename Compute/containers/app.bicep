extension radius
extension containers

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'test-app'
  location: 'global'
  properties: {
    environment: environment
  }
}

resource ctnr 'Radius.Compute/containers@2023-10-01-preview' = {
  name: 'ctnr'
  location: 'global'
  properties: {
    application: app.id
    environment: environment
  }
}
