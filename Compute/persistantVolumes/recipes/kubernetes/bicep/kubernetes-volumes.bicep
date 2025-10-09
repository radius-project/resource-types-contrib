param context object


@description('Storage Class for the persistent volume')
param storageClass string = ''

extension kubernetes with {
  namespace: context.runtime.kubernetes.namespace
  kubeConfig: ''

} as kubernetes

resource persistentVolumeClaim 'core/PersistentVolumeClaim@v1' = {
  metadata: {
   name: context.resource.name
    labels: {
      'radapp.io/resource': context.resource.name
      'radapp.io/environment': context.resource.properties.environment != null ? context.resource.properties.environment : ''
      // Label pods with the application name so `rad run` can find the logs.
      'radapp.io/application': context.application == null ? '' : context.application.name
    }
  }
  spec: union({
    storageClassName: storageClass
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
      'ReadOnlyMany' 
      'ReadWriteMany'
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
}
