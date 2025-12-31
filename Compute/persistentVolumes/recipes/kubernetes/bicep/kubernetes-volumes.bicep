param context object

var resourceName = context.resource.name
var environmentSegments = context.resource.properties.environment != null ? split(string(context.resource.properties.environment), '/') : []
var environmentLabel = length(environmentSegments) > 0 ? last(environmentSegments) : ''

@description('Storage Class for the persistent volume')
param storageClass string = ''

extension kubernetes with {
  namespace: context.runtime.kubernetes.namespace
  kubeConfig: ''

} as kubernetes

resource persistentVolumeClaim 'core/PersistentVolumeClaim@v1' = {
  metadata: {
    name: resourceName
    labels: {
      'radapp.io/resource': resourceName
      'radapp.io/environment': environmentLabel
      // Label pods with the application name so `rad run` can find the logs.
      'radapp.io/application': context.application == null ? '' : context.application.name
    }
  }
  spec: union(
    empty(storageClass) ? {} : {
      storageClassName: storageClass
    },
    {
    resources: {
      requests: {
        storage: '${context.resource.properties.sizeInGib}Gi'
      }
    }
  }, contains(context.resource.properties, 'allowedAccessModes') ? {
    accessModes: [
      context.resource.properties.allowedAccessModes
    ]
  } : {
    accessModes: [
      'ReadWriteOnce'
    ]
  })
}

output result object = {
  // This workaround is needed because the deployment engine omits Kubernetes resources from its output.
  // This allows Kubernetes resources to be cleaned up when the resource is deleted.
  // Once this gap is addressed, users won't need to do this.
  resources: [
    '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/core/PersistentVolumeClaim/${persistentVolumeClaim.metadata.name}'
  ]
  values: {
    claimName: persistentVolumeClaim.metadata.name
  }
}
