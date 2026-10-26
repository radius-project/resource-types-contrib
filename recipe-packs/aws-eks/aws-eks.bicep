extension radius

@description('Name of the EKS cluster that runs the application. AWS Recipes attach their services to the cluster security group so pods can reach them.')
param eksClusterName string

@description('Comma-separated IDs of VPC subnets for AWS Recipes that need a subnet group, for example subnet-0abc,subnet-0def. Use subnets in the EKS cluster VPC that span at least two Availability Zones. A JSON array string is also accepted.')
param subnetIds string

@description('Name of the Kubernetes Gateway resource that Radius.Compute/routes attach to. Must already exist in the cluster.')
param routesGatewayName string

@description('Namespace where the Kubernetes Gateway resource for Radius.Compute/routes is located.')
param routesGatewayNamespace string = 'default'

@description('Registry path (e.g. ghcr.io/my-org) that Radius.Compute/containerImages pushes built images to.')
param containerImagesRegistry string

@description('Name of the Kubernetes Secret holding registry credentials for Radius.Compute/containerImages. Leave empty for an unauthenticated registry.')
param containerImagesRegistrySecretName string = ''

resource awsEksRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'aws-eks'
  properties: {
    recipes: {
      'Radius.Data/mySqlDatabases': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/aws-eks-recipes/mysqldatabases:latest'
        parameters: {
          eksClusterName: eksClusterName
          subnetIds: subnetIds
        }
      }
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containers:latest'
      }
      'Radius.Compute/persistentVolumes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/persistentvolumes:latest'
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/secrets:latest'
      }
      'Radius.Compute/routes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/routes:latest'
        parameters: {
          gatewayName: routesGatewayName
          gatewayNamespace: routesGatewayNamespace
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
    }
  }
}
