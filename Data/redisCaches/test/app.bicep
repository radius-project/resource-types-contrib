extension radius

extension redisCaches

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'redis-azure-test'
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
        image: 'ghcr.io/radius-project/samples/demo:latest'
        ports: {
          web: {
            containerPort: 3000
          }
        }
      }
    }
    connections: {
      redis: {
        source: redis.id
      }
    }
  }
}
