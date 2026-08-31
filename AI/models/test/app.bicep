extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'models-azure-test'
  properties: {
    environment: environment
  }
}

resource model 'Radius.AI/models@2025-08-01-preview' = {
  name: 'model'
  properties: {
    environment: environment
    application: app.id
    model: 'gpt-5-mini'
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
        // Portable explicit wiring remains valid on all supported Container Recipes.
        env: {
          MODEL_APIKEY: {
            valueFrom: {
              secretKeyRef: {
                secretName: model.properties.secrets.name
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
      // On compatible Kubernetes versions, injects model/endpoint plus
      // secret-backed CONNECTION_LLM_APIKEY. Explicit env wiring remains supported.
      llm: {
        source: model.id
      }
    }
  }
}
