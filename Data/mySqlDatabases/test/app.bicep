extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Database admin password. Set on the resource `password` property (x-radius-sensitive), so Radius encrypts it at rest and injects it decrypted into the Recipe as the flexible server administrator password.')
@secure()
param password string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'mysql-azure-test'
  properties: {
    environment: environment
  }
}

resource mysql 'Radius.Data/mySqlDatabases@2025-08-01-preview' = {
  name: 'mysql'
  properties: {
    environment: environment
    application: app.id
    version: '8.0'
    database: 'appdb'
    username: 'radadmin'
    password: password
  }
}

resource demoImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'mysql-demo-image'
  properties: {
    environment: environment
    application: app.id
    tag: 'demo-e2e'
    build: {
      source: 'git::https://github.com/radius-project/samples.git//samples/demo?ref=190d9c4c84278980d9fae402330bd5ead76b31a5'
    }
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
      mysqldb: {
        source: mysql.id
      }
    }
  }
}
