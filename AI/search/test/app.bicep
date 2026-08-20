extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'search-azure-test'
  properties: {
    environment: environment
  }
}

resource searchService 'Radius.AI/search@2025-08-01-preview' = {
  name: 'search'
  properties: {
    environment: environment
    application: app.id
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
        // The recipe's secret output(s) are materialized into a managed
        // Radius.Security/secrets resource and consumed here BY REFERENCE via
        // secretKeyRef — the value never lands on searchService state.
        env: {
          SEARCH_APIKEY: {
            valueFrom: {
              secretKeyRef: {
                secretName: searchService.properties.secrets.name
                key: 'apiKey'
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
      search: {
        source: searchService.id
      }
    }
  }
}
