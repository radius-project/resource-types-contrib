extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'objectstorage-azure-test'
  properties: {
    environment: environment
  }
}

resource store 'Radius.Storage/objectStorage@2025-08-01-preview' = {
  name: 'store'
  properties: {
    environment: environment
    application: app.id
    containerName: 'data'
  }
}

resource democtr 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'democtr'
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
      storage: {
        source: store.id
      }
    }
  }
}
