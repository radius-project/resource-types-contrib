extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Application name. Deployment tests set this to the same name used by the CLI and cleanup.')
param applicationName string = 'postgresql-test'

@description('Database admin password. Set on the `password` property of the database (x-radius-sensitive, so Radius encrypts it at rest and injects it decrypted into the Recipe) and stored in a Radius.Security/secrets resource for the consuming container to bind by reference.')
@secure()
param password string

@description('Use default to omit tls and exercise the schema default, or select an explicit transport policy.')
@allowed(['default', 'required', 'optional'])
param tlsPolicy string = 'default'

@description('Initialization SQL used by the Bicep Kubernetes recipe tests. Terraform does not implement initSql.')
param initSql string = ''

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

// The password is also needed by the consuming container. Store it in a
// Radius.Security/secrets resource rather than passing it to the container as a
// plain `env` value: `data.value` is x-radius-sensitive (encrypted at rest,
// redacted on reads), whereas a container `env.value` is stored unencrypted on
// the container resource and rendered literally into the Pod spec.
resource dbCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  // Keep this distinct from the Recipe-owned `postgresql-credentials`
  // Kubernetes Secret that configures the PostgreSQL container.
  name: 'postgresql-client-credentials'
  properties: {
    environment: environment
    application: app.id
    data: {
      password: {
        value: password
      }
    }
  }
}

resource postgresql 'Radius.Data/postgreSqlDatabases@2025-08-01-preview' = {
  name: 'postgresql'
  properties: union({
    environment: environment
    application: app.id
    size: 'S'
    database: 'appdb'
    username: 'radadmin'
    password: password
    initSql: initSql
  }, tlsPolicy == 'default' ? {} : { tls: tlsPolicy })
}

resource democontainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'democontainer'
  properties: {
    environment: environment
    application: app.id
    containers: {
      demo: {
        image: 'ghcr.io/radius-project/samples/demo:latest'
        // Host, port, username, and database arrive automatically as
        // CONNECTION_POSTGRESQL_* env vars from the connection below. The
        // connection cannot carry the password (x-radius-sensitive properties
        // redact to null on reads and are skipped), so it is bound by reference
        // here under the same naming scheme, filling the one gap the connection
        // leaves. The value never lands in the Pod spec or on this container.
        env: {
          CONNECTION_POSTGRESQL_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: dbCreds.name
                key: 'password'
              }
            }
          }
        }
        ports: {
          web: {
            containerPort: 3000
          }
        }
      }
    }
    connections: {
      // Named `postgresql` so the injected variables are CONNECTION_POSTGRESQL_*,
      // which is the prefix the demo image looks for.
      postgresql: {
        source: postgresql.id
      }
    }
  }
}
