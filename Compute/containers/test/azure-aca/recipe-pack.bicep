extension radius

@description('Recipe kind for the target-owned ACA deployment.')
@allowed(['bicep', 'terraform'])
param recipeKind string = 'bicep'

@description('Immutable published Bicep OCI source or Terraform module URL.')
param containerRecipeSource string

@description('Existing Azure Container Apps managed environment name.')
param containerAppsEnvironmentName string

@description('Region of the existing environment; passed only to Bicep.')
param containerAppsLocation string

resource acaRecipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aca-tcp'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: recipeKind
        source: containerRecipeSource
        acceptsDelegationFrom: ['Radius.Compute/routes']
        parameters: union({
          containerAppsEnvironmentName: containerAppsEnvironmentName
        }, recipeKind == 'bicep' ? {
          containerAppsLocation: containerAppsLocation
        } : {})
      }
      'Radius.Compute/routes': {
        kind: 'delegated'
        delegatesTo: 'Radius.Compute/containers'
      }
    }
  }
}
