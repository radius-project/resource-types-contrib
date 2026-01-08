//
// PostgreSQL test case
//
// Test script:
//
// rad deploy app.bicep -p password=$(openssl rand -hex 16)
// Typically use base64 instead of hex, but the todolist has a bug where is does not handle special characters in the password
// Manually verify todolist application can create and delete tasks

extension radius
extension postgreSqlDatabases
extension secrets

@description('The Radius environment ID')
param environment string

@secure()
param password string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'todolist'
  properties: {
    environment: environment
  }
}

resource frontend 'Applications.Core/containers@2023-10-01-preview' = {
  name: 'frontend'
  properties: {
    application: app.id
    environment: environment
    container: {
      image: 'ghcr.io/radius-project/samples/demo:latest'
      ports: {
        web: {
          containerPort: 3000
        }
      }
      // TODO: Remove after https://github.com/radius-project/radius/issues/10870
      env: {
        CONNECTION_POSTGRESQL_USERNAME: {
          valueFrom: {
            secretRef: {
              key: 'username'
              source: 'todolist-credentials-default'
            }
          }
        }
        CONNECTION_POSTGRESQL_PASSWORD: {
          valueFrom: {
            secretRef: {
              key: 'password'
              source: 'todolist-credentials-default'
            }
          }
        }
      }
    }
    connections: {
      postgresql: {
        source: postgresql.id
      }
      credentials: {
        source: credentials.id
      }
    }
  }
}

resource postgresql 'Radius.Data/postgreSqlDatabases@2025-08-01-preview' = {
  name: 'postgresql'
  properties: {
    application: app.id
    environment: environment
    size: 'S'
    connections: {
      credentials: {
        source: credentials.id
      }
    }
  }
}

resource credentials 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'credentials'
  properties: {
    environment: environment
    application: app.id
    data: {
      username: {
        value: 'postgres'
      }
      password: {
        value: password
      }
    }
    kind: 'basicAuthentication'
  }
}
