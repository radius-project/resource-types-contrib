extension radius
extension containers
extension postgreSqlDatabases
extension secrets

@description('The Radius environment ID')
param environment string

@secure()
param password string

resource myapp 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'myapp'
  properties: {
    environment: environment
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
      postgresql: {
        source: postgresql.id
        
      }
    }
  }
}

resource postgresql 'Radius.Data/postgreSqlDatabases@2025-08-01-preview' = {
  name: 'postgresql'
  properties: {
    environment: environment
    application: myapp.id
    size: 'S'
    secretName: dbSecret.name
  }
}

resource dbSecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'dbsecret'
  properties: {
    environment: environment
    application: myapp.id
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
