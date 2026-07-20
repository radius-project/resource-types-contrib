// Default Radius recipe pack
//
// Deploy with:
//   rad deploy recipepack/kubernetes/default-recipepack.bicep
//
// This mirrors /planes/radius/local/resourceGroups/default/providers/Radius.Core/recipePacks/default

extension radius

resource defaultRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'default'
  location: 'global'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containers:latest'
      }
      'Radius.Compute/persistentVolumes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/persistentvolumes:latest'
      }
      'Radius.Compute/routes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/routes:latest'
        parameters: {
          gatewayName: 'radius'
          gatewayNamespace: 'radius-system'
        }
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/secrets:latest'
      }
      'Radius.Data/mySqlDatabases': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/mysqldatabases:latest'
      }
    }
  }
}
