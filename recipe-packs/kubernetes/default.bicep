// Default Radius recipe pack
//
// Deploy into an existing Environment, then associate the pack:
//   rad deploy recipe-packs/kubernetes/default.bicep --environment default
//   rad env update default --recipe-packs default --preview
//
// This mirrors /planes/radius/local/resourceGroups/default/providers/Radius.Core/recipePacks/default

extension radius

@description('Registry path that Radius.Compute/containerImages pushes built images to. Defaults to the in-cluster registry that the Radius Helm chart exposes on NodePort 31500. Set to an external registry (e.g. ghcr.io/my-org) when the in-cluster registry is disabled.')
param containerImagesRegistry string = 'localhost:31500'

@description('Name of the Kubernetes Secret holding registry credentials for Radius.Compute/containerImages. Leave empty for an unauthenticated registry such as the default in-cluster registry.')
param containerImagesRegistrySecretName string = ''

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
      'Radius.Compute/containerImages': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containerimages:latest'
        parameters: {
          registry: containerImagesRegistry
          registrySecretName: containerImagesRegistrySecretName
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
      'Radius.Messaging/rabbitMQ': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/rabbitmq:latest'
      }
    }
  }
}
