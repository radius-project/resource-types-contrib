extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Database admin password. Set on the resource `password` property (x-radius-sensitive), so Radius encrypts it at rest and injects it decrypted into the Recipe as the flexible server administrator password.')
@secure()
param password string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'postgresql-azure-test'
  properties: {
    environment: environment
  }
}

resource postgresql 'Radius.Data/postgreSqlDatabases@2025-08-01-preview' = {
  name: 'postgresql'
  properties: {
    environment: environment
    application: app.id
    size: 'S'
    database: 'appdb'
    username: 'radadmin'
    password: password
  }
}

resource demoImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'postgresql-demo-image'
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
      postgres: {
        source: postgresql.id
      }
    }
  }
}
