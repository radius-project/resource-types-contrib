extension radius
extension secrets

@description('The Radius environment ID')
param environment string

@secure()
param password string

resource testapp 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'testapp'
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

