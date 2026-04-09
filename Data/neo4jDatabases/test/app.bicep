extension radius
extension containers
extension neo4jDatabases
extension secrets

@description('The Radius environment ID')
param environment string

@secure()
param password string

@description('The container image for the test app')
param testImage string = 'ghcr.io/reshrahim/radius-test:latest'

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
      neo4jtest: {
        image: testImage
        ports: {
          web: {
            containerPort: 3000
          }
        }
      }
    }
    connections: {
      neo4j: {
        source: neo4j.id
      }
    }
  }
}

resource neo4j 'Radius.Data/neo4jDatabases@2025-09-11-preview' = {
  name: 'neo4j'
  properties: {
    environment: environment
    application: myapp.id
    secretName: dbSecret.name
  }
}

resource dbSecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'dbsecret'
  properties: {
    environment: environment
    application: myapp.id
    data: {
      USERNAME: {
        value: 'neo4j'
      }
      PASSWORD: {
        value: password
      }
    }
  }
}
