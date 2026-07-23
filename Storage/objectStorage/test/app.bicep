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

resource demoImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'objectstorage-demo-image'
  properties: {
    environment: environment
    application: app.id
    tag: 'demo-e2e'
    build: {
      source: 'git::https://github.com/radius-project/samples.git//samples/demo?ref=190d9c4c84278980d9fae402330bd5ead76b31a5'
    }
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
        // The recipe's secret output(s) are materialized into a managed
        // Radius.Security/secrets resource and consumed here BY REFERENCE via
        // secretKeyRef — the value never lands on store state.
        env: {
          STORAGE_CONNECTIONSTRING: {
            valueFrom: {
              secretKeyRef: {
                secretName: store.properties.secrets.name
                key: 'connectionString'
              }
            }
          }
          STORAGE_ACCOUNTKEY: {
            valueFrom: {
              secretKeyRef: {
                secretName: store.properties.secrets.name
                key: 'accountKey'
              }
            }
          }
        }
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
