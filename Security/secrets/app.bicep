extension radius
extension secrets

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'test-app'
  location: 'global'
  properties: {
    environment: environment
  }
}

resource appSecrets 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'app-secrets'
  properties: {
    environment: environment
    application: app.id             // kind field (not provided in the eg.) will default to 'generic'
    data: {
      username: { value: 'appuser' }  // uses default 'string' encoding
      password: { value: 'c2VjcmV0Cg==', encoding: 'base64' }
      apiToken: { value: 'akv://mainvault/secrets/apiToken' }  // external URI
    }
  }
}
