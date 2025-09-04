extension radius
extension secrets

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'testapp'
  location: 'global'
  properties: {
    environment: environment
    extensions: [
      {
        kind: 'kubernetesNamespace'
        namespace: 'testapp'
      }
    ]
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

