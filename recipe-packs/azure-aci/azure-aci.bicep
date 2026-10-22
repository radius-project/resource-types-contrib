extension radius

resource azureAciRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aci'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-aci-recipes/containers:0c3eaf14e7acc074420e78fda4d66c51541a8145'
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
