extension radius
extension containerImages
extension containers

param environment string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'containerimages-testapp'
  properties: {
    environment: environment
  }
}

resource testImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'test-image'
  properties: {
    environment: environment
    application: app.id
    image: 'ghcr.io/radius-project/samples/demo:latest'
    build: {
      context: '/app/test'
    }
  }
}

resource testContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'test-container'
  properties: {
    environment: environment
    application: app.id
    containers: {
      app: {
        image: testImage.properties.image
        ports: {
          web: {
            containerPort: 3000
          }
        }
      }
    }
    connections: {
      image: {
        source: testImage.id
      }
    }
  }
}
