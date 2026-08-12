// Default Radius recipe pack. This is the Kubernetes pack that `rad init` installs as the
// `default` recipe pack; `rad init` embeds its own copy, so keep the two in sync.
//
// Deploy with:
//   rad deploy recipe-packs/kubernetes/kubernetes-recipe-pack.bicep
//
// This mirrors /planes/radius/local/resourceGroups/default/providers/Radius.Core/recipePacks/default

extension radius

@description('Name of the Radius environment to create.')
param environmentName string = 'default'

@description('Kubernetes namespace the Radius environment deploys resources into.')
param environmentNamespace string = 'default'

resource kubernetesRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'default'
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
      'Radius.Data/redisCaches': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/rediscaches:latest'
      }
    }
  }
}

resource env 'Radius.Core/environments@2025-08-01-preview' = {
  name: environmentName
  properties: {
    providers: {
      kubernetes: {
        namespace: environmentNamespace
      }
    }
    recipePacks: [
      kubernetesRecipePack.id
    ]
  }
}
