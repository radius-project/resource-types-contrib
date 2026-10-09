extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Application name. CI supplies a unique name for deployment and cleanup.')
param applicationName string = 'sqlserver-azure-test'

@description('Database username.')
param username string = 'radadmin'

@description('Database password.')
@secure()
param password string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
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
    username: username
    password: password
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
