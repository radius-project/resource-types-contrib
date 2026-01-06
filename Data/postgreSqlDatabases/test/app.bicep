extension radius

extension radiusCompute

extension radiusData

extension radiusSecurity

param environment string

@secure()
param password string

resource todoapp 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'todoapp'
  properties: {
    environment: environment
  }
}

resource mycontainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'mycontainer'
  properties: {
    environment: environment
    application: todoapp.id
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
    application: todoapp.id
    size: 'S'
    secretName: dbSecret.name
  }
}

resource dbSecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'dbsecret'
  properties: {
    environment: environment
    application: todoapp.id
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
