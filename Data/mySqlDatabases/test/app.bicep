extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Database admin password. Set on the resource `password` property (x-radius-sensitive), so Radius encrypts it at rest and injects it decrypted into the Recipe as the flexible server administrator password.')
@secure()
param password string

@description('Test-only selector; omitted leaves the tls resource property absent.')
@allowed([
  'omitted'
  'required'
  'optional'
])
param tlsPolicy string = 'omitted'

@description('Distinct application name for each policy deployment.')
param applicationName string = 'mysql-test'

var databaseName = 'appdb'
var username = 'radadmin'
var tlsAssertions = replace(loadTextContent('assert-tls.sh'), '\r', '')

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

// The consuming client needs the same developer-owned password as the database.
// Keep it in an authored Radius Secret so it is projected into the Pod by
// reference rather than stored on the container resource or in the Pod spec.
resource clientCredentials 'Radius.Security/secrets@2025-08-01-preview' = {
  // The MySQL Recipe owns `mysql-credentials`; this distinct name prevents the
  // authored Secret from colliding with the Recipe-owned Kubernetes Secret.
  name: 'mysql-client-credentials'
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

resource mysql 'Radius.Data/mySqlDatabases@2025-08-01-preview' = {
  name: 'mysql'
  properties: union({
    environment: environment
    application: app.id
    version: '8.0'
    database: databaseName
    username: username
    password: password
  }, tlsPolicy == 'omitted' ? {} : {
    tls: tlsPolicy == 'optional' ? 'optional' : 'required'
  })
}

resource mysqlclient 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'mysqlclient'
  properties: {
    environment: environment
    application: app.id
    containers: {
      client: {
        image: 'mysql:8.0'
        command: [
          '/bin/sh'
          '-c'
        ]
        args: [
          '${tlsAssertions}\n${'''
touch /tmp/mysql-ready
while true; do
  sleep 3600
done
'''}'
        ]
        env: {
          MYSQL_TLS_POLICY: {
            value: tlsPolicy
          }
          // MYSQL_HOST selects the real MySQL endpoint. The host reference and
          // connection below both preserve database-before-client ordering.
          MYSQL_HOST: {
            value: mysql.properties.host
          }
          MYSQL_PORT: {
            value: string(mysql.properties.port)
          }
          MYSQL_DB: {
            value: databaseName
          }
          MYSQL_USER: {
            value: username
          }
          MYSQL_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: clientCredentials.name
                key: 'password'
              }
            }
          }
        }
        readinessProbe: {
          exec: {
            command: [
              '/bin/sh'
              '-c'
              'test -f /tmp/mysql-ready'
            ]
          }
          periodSeconds: 2
          failureThreshold: 30
        }
      }
    }
    connections: {
      mysql: {
        source: mysql.id
        // The client uses its native MYSQL_* contract above. Disable the
        // generic CONNECTION_MYSQL_* projection to keep one source per value.
        disableDefaultEnvVars: true
      }
    }
  }
}
