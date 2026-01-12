extension radius
extension secrets

param environment string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'testapp'
  location: 'global'
  properties: {
    environment: environment
  }
}

resource secret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'app-secrets-${uniqueString(deployment().name)}'
  properties: {
    environment: environment
    application: app.id
    data: {
      username: {
        value: 'admin'
      }
      password: {
        value: 'c2VjcmV0cGFzc3dvcmQ='
        encoding: 'base64'
      }
      apikey: {
        value: 'abc123xyz'
      }
    }
  }
}

