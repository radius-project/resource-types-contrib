extension radius

resource azureAciRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aci'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-aci-recipes/containers@sha256:4295fac3aded4a823e0de8394c5996833fedd35206614497ec3caa32b8cbc278'
      }
      'Radius.Compute/persistentVolumes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-aci-recipes/persistentvolumes:latest'
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-aci-recipes/secrets:latest'
      }
    }
  }
}
