extension radius
extension containerImages
extension containers
extension secrets

param environment string

@secure()
param registryPassword string

param registryUsername string

param registryServer string = 'ghcr.io'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'containerimages-testapp'
  properties: {
    environment: environment
  }
}

resource registryCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'registry-creds'
  properties: {
    environment: environment
    application: app.id
    kind: 'dockerconfigjson'
    data: {
      username: {
        value: registryUsername
      }
      password: {
        value: registryPassword
      }
      server: {
        value: registryServer
      }
    }
  }
}

resource testImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'test-image'
  properties: {
    environment: environment
    application: app.id
    secretName: registryCreds.name
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
    imagePullSecrets: [registryCreds.name]
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
