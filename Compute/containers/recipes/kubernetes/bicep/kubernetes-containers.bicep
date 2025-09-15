@description('Radius-provided deployment context (resource properties and metadata).')
param context object

extension kubernetes with {
  namespace: context.runtime.kubernetes.namespace
  kubeConfig: ''
} as kubernetes

// Extract container information from context
var containers = context.resource.properties.containers
var resourceName = context.resource.name
var containerNames = objectKeys(containers)

// Create separate Deployment for each container
resource deployments 'apps/Deployment@v1' = [for containerName in containerNames: {
  metadata: {
    name: '${toLower(resourceName)}-${containerName}'
    namespace: context.runtime.kubernetes.namespace
    labels: {
      'app.kubernetes.io/name': '${toLower(resourceName)}-${containerName}'
    }
  }
  spec: {
    replicas: 1
    selector: {
      matchLabels: {
        'app.kubernetes.io/name': '${toLower(resourceName)}-${containerName}'
      }
    }
    template: {
      metadata: {
        labels: {
          'app.kubernetes.io/name': '${toLower(resourceName)}-${containerName}'
        }
      }
      spec: {
        containers: [
          {
            name: containerName
            image: containers[containerName].image
            ports: [
              {
                containerPort: containers[containerName].ports.web.containerPort
                name: 'web'
              }
            ]
            resources: {
              requests: {
                cpu: '10m'
                memory: '64Mi'
              }
            }
          }
        ]
      }
    }
  }
}]

// Create services for each container
resource containerServices 'core/Service@v1' = [for containerName in containerNames: {
  metadata: {
    name: '${toLower(resourceName)}-${containerName}'
    namespace: context.runtime.kubernetes.namespace
  }
  spec: {
    selector: {
      'app.kubernetes.io/name': '${toLower(resourceName)}-${containerName}'
    }
    ports: [
      {
        port: 80
        targetPort: 'web'
        name: 'http'
        protocol: 'TCP'
      }
    ]
    type: 'ClusterIP'
  }
}]

var deploymentResourcePaths = [for containerName in containerNames: '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/apps/Deployment/${toLower(resourceName)}-${containerName}']
var serviceResourcePaths = [for containerName in containerNames: '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/core/Service/${toLower(resourceName)}-${containerName}']

output result object = {
  values: {
    containerCount: length(containerNames)
    containerNames: containerNames
  }
  secrets: {}
  resources: concat(deploymentResourcePaths, serviceResourcePaths)
}
