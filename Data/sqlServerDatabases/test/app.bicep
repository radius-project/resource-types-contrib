extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Database username.')
@secure()
param dbUsername string

@description('Database password.')
@secure()
param dbPassword string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'sqlserver-azure-test'
  properties: {
    environment: environment
  }
}

resource sqlserver 'Radius.Data/sqlServerDatabases@2025-08-01-preview' = {
  name: 'sqlserver'
  properties: {
    environment: environment
    application: app.id
    database: 'appdb'
    username: dbUsername
    password: dbPassword
  }
}

resource democontainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'democontainer'
  properties: {
    environment: environment
    application: app.id
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
      sql: {
        source: sqlserver.id
      }
    }
  }
}
