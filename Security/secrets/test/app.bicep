extension radius

@description('The Radius environment ID')
param environment string

@description('Application name. CI supplies a unique name for deployment and cleanup.')
param applicationName string = 'testapp'

@secure()
param password string

resource testapp 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  location: 'global'
  properties: {
    environment: environment
  }
}

resource testsecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'dbsecret'
  properties: {
    environment: environment
    application: testapp.id
    data: {
      username: {
        value: 'admin'
      }
      password: {
        value: password
      }
    }
  }
}
