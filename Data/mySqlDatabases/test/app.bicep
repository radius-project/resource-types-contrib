extension radius
extension containers
extension mySqlDatabases
extension secrets

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
  name: 'dbsecret'
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

resource mycontainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'mycontainer'
  properties: {
    environment: environment
    application: myapp.id
    containers: {
      demo: {
        image: 'ghcr.io/radius-project/samples/demo:latest'
        ports: {
          web: {
            containerPort: 3000
          }
        }
      }
    }
    connections: {
      mysql: {
        source: mysql.id
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
