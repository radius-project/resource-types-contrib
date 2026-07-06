extension radius

extension mongoDatabases

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

var databaseName = 'mongo_db'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'mongodb-azure-test'
  properties: {
    environment: environment
  }
}

resource mongo 'Radius.Data/mongoDatabases@2025-08-01-preview' = {
  name: 'mongo'
  properties: {
    environment: environment
    application: app.id
    database: databaseName
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
      mongodb: {
        source: mongo.id
      }
    }
  }
}
