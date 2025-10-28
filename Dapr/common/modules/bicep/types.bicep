@export()
@description('Generic metadata property for a Dapr component')
type DaprMetadata = {
  @description('Required. The name of the metadata property')
  name: string

  @description('Optional. The value of the metadata property')
  value: string

  @description('Optional. The secret key referencethat contains the value of the metadata property')
  secretKeyRef: DaprSecretRef
}

@export()
@description('Reference to a secret key in a dapr secret store')
type DaprSecretRef = {
  @description('Required. The name of the secret store')
  name: string

  @description('Required. The key of the secret')
  key: string
}

@export()
@description('Output values for a Dapr component')
type result = {
  @description('List of resource IDs created for this component. These will be cleaned up when the component is deleted.')
  // This workaround is needed because the deployment engine omits Kubernetes resources from its output.
  // This allows Kubernetes resources to be cleaned up when the resource is deleted.
  // Once this gap is addressed, users won't need to do this.
  resources: string[]
  @description('Values exposed by the component when using a connection')
  values: {
    @description('Dapr component type, e.g. state.redis')
    type: string
    @description('Dapr component name')
    componentName: string
  }
}
