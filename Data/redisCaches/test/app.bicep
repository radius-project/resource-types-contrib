extension radius
extension containers
extension redisCaches
extension secrets

@description('The Radius environment ID')
param environment string

@secure()
param password string

@description('The container image for the test app')
param testImage string = 'ghcr.io/reshrahim/redis-test:latest'

resource myapp 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'myapp'
  properties: {
    environment: environment
  }
}

resource mycontainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'mycontainer'
  properties: {
    environment: environment
    application: myapp.id
    containers: {
      redistest: {
        image: testImage
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

resource redis 'Radius.Data/redisCaches@2025-08-01-preview' = {
  name: 'redis'
  properties: {
    environment: environment
    application: myapp.id
    size: 'S'
    secretName: redisSecret.name
  }
}

resource redisSecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'redissecret'
  properties: {
    environment: environment
    application: myapp.id
    data: {
      PASSWORD: {
        value: password
      }
    }
  }
}
