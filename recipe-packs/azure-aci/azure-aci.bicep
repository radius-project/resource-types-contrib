extension radius

@description('ACI container recipe source. Override to test a recipe built from this checkout.')
param aciContainerRecipeSource string = 'ghcr.io/radius-project/azure-aci-recipes/containers:latest'

@description('Use plain HTTP to retrieve the ACI container recipe from a local registry.')
param aciContainerRecipePlainHttp bool = false

resource azureAciRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aci'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: aciContainerRecipeSource
        plainHttp: aciContainerRecipePlainHttp
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
