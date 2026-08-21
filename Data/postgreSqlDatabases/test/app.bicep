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

// Regression coverage for issue #299. Azure pre-creates a `postgres` database on
// every PostgreSQL flexible server, so the Azure Recipe must bind to the existing
// one rather than ask Azure to create it a second time. Before the fix this
// deployment failed with `InvalidParameterValue: Invalid value given for parameter
// databaseName`, after the server had already been created.
//
// This is deliberately the only PostgreSQL resource in the test application rather
// than an addition alongside one requesting an ordinary database name. Each resource
// provisions its own flexible server, which takes long enough that a second one puts
// the Azure validation job near its 30 minute timeout, so the reserved name is the
// path worth spending the budget on.
resource postgresql 'Radius.Data/postgreSqlDatabases@2026-09-01-preview' = {
  name: 'postgresql'
  properties: {
    environment: environment
    application: app.id
    size: 'S'
    database: 'postgres'
    username: 'radadmin'
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
      postgres: {
        source: postgresql.id
      }
    }
  }
}
