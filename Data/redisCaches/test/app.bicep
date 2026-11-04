extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Application name. CI supplies a unique name for deployment and cleanup.')
param applicationName string = 'redis-azure-test'

@description('Azure tests also check TLS, the separate access key, and the StackExchange.Redis connection string.')
@allowed([
  'kubernetes'
  'azure'
])
param cachePlatform string = 'kubernetes'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

resource redis 'Radius.Data/redisCaches@2025-08-01-preview' = {
  name: 'redis'
  properties: {
    environment: environment
    application: app.id
    size: 'S'
  }
}

resource democontainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'democontainer'
  properties: {
    environment: environment
    application: app.id
    containers: {
      demo: {
        image: 'redis:7-alpine'
        command: [
          '/bin/sh'
          '-c'
        ]
        args: [
          'while true; do sleep 3600; done'
        ]
        // The recipe's secret output(s) are materialized into a managed
        // Radius.Security/secrets resource and consumed here BY REFERENCE via
        // secretKeyRef — the value never lands on redis state.
        env: union({
          REDIS_PLATFORM: {
            value: cachePlatform
          }
          REDIS_HOST: {
            value: redis.properties.host
          }
          REDIS_PORT: {
            value: string(redis.properties.port)
          }
          REDIS_URL: {
            valueFrom: {
              secretKeyRef: {
                secretName: redis.properties.secrets.name
                key: 'url'
              }
            }
          }
        }, cachePlatform == 'azure' ? {
          REDIS_ACCESS_KEY: {
            valueFrom: {
              secretKeyRef: {
                secretName: redis.properties.secrets.name
                key: 'accessKey'
              }
            }
          }
          REDIS_CONNECTION_STRING: {
            valueFrom: {
              secretKeyRef: {
                secretName: redis.properties.secrets.name
                key: 'connectionString'
              }
            }
          }
        } : {})
        readinessProbe: {
          exec: {
            command: [
              '/bin/sh'
              '-c'
              loadTextContent('verify-connection.sh')
            ]
          }
          periodSeconds: 5
          timeoutSeconds: 10
          failureThreshold: 30
        }
      }
    }
    connections: {
      redis: {
        source: redis.id
        disableDefaultEnvVars: true
      }
    }
  }
}
