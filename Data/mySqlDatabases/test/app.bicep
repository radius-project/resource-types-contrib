extension radius
extension mySqlDatabases
extension secrets

@description('The Radius environment ID')
param environment string

@secure()
param password string

resource testapp 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'testapp'
  location: 'global'
  properties: {
    environment: environment
  }
}

resource dbSecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'dbsecret'
  properties: {
    environment: environment
    application: testapp.id
    data: {
      USERNAME: {
        value: 'admin'
      }
      PASSWORD: {
        value: password
      }
    }
  }
}

resource mysql 'Radius.Data/mySqlDatabases@2025-08-01-preview' = {
  name: 'mysql'
  properties: {
    environment: environment
    application: testapp.id
    secretName: dbSecret.name
  }
}
