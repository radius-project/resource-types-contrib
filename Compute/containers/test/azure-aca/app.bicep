extension radius
extension containers
extension routes

@description('Radius environment using the experimental ACA TCP recipe pack.')
param environment string

@description('Unique test application name.')
param applicationName string = 'aca-tcp-example'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

resource workload 'containers:Radius.Compute/containers@2025-08-01-preview' = {
  name: '${applicationName}-workload'
  properties: {
    environment: environment
    application: app.id
    replicas: 1
    containers: {
      cache: {
        image: 'redis:7-alpine'
        command: ['redis-server']
        args: ['--port', '6379']
        ports: { redis: { containerPort: 6379 } }
      }
      queue: {
        image: 'redis:7-alpine'
        command: ['redis-server']
        args: ['--port', '9000']
        ports: { redis: { containerPort: 9000 } }
      }
    }
  }
}

resource cacheRoute 'routes:Radius.Compute/routes@2025-08-01-preview' = {
  name: '${applicationName}-cache'
  properties: {
    environment: environment
    application: app.id
    kind: 'TCP'
    rules: [{
      matches: []
      destinationContainer: {
        resourceId: workload.id
        containerName: 'cache'
        containerPort: 6379
      }
    }]
  }
}

resource queueRoute 'routes:Radius.Compute/routes@2025-08-01-preview' = {
  name: '${applicationName}-queue'
  properties: {
    environment: environment
    application: app.id
    kind: 'TCP'
    rules: [{
      matches: []
      destinationContainer: {
        resourceId: workload.id
        containerName: 'queue'
        containerPort: 9000
      }
    }]
  }
}
