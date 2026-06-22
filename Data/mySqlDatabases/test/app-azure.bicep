extension radius

@description('The Radius environment ID')
param environment string

@secure()
param password string

resource myapp 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'myapp'
  location: 'global'
  properties: {
    environment: environment
  }
}

resource dbSecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'mysqlsecret'
  properties: {
    environment: environment
    application: myapp.id
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
    application: myapp.id
    secretName: dbSecret.name
  }
}
