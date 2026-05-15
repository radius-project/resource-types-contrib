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
    tag: 'test'
    build: {
      context: 'git::https://github.com/radius-project/samples.git//demo'
    }
  }
}

resource testContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'test-container'
  properties: {
    environment: environment
    application: app.id
    imagePullSecrets: [testImage.properties.imagePullSecretName]
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
