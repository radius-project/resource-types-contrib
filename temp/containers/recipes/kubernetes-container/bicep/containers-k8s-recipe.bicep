@description('Name of the application')
param applicationName string = 'sample-app'

@description('Name of the resource')
param resourceName string = 'sample-container'

@description('Container image to deploy')
param containerImage string = 'nginx:latest'

@description('Container port configuration')
param containerPort int = 8080

@description('Kubernetes namespace')
param kubernetesNamespace string = 'default'

extension kubernetes with {
  kubeConfig: ''
  namespace: kubernetesNamespace
} as kubernetes

resource deployment 'apps/Deployment@v1' = {
  metadata: {
    name: '${resourceName}-deployment'
    labels: {
      app: applicationName
      resource: resourceName
    }
  }
  spec: {
    selector: {
      matchLabels: {
        app: applicationName
        resource: resourceName
      }
    }
    template: {
      metadata: {
        labels: {
          app: applicationName
          resource: resourceName
          // Label pods with the application name so `rad run` can find the logs.
          'radapp.io/application': applicationName
        }
      }
      spec: {
        containers: [
          {
            name: resourceName
            image: containerImage
            // TODO: Convert to array
            // TODO: Add handling null values for optional properties
            // env: context.resource.properties.container.env
            // TODO: Convert to array
            // TODO: Add handling null values for optional properties
            // command: context.resource.properties.container.command
            // TODO: Convert to array
            // TODO: Needs further testing for handling null values for optional properties
            // args: empty(context.resource.properties.container.args) ? [] : context.resource.properties.container.args
            // workingDir: context.resource.properties.container.workingDir
            // TODO: Convert to array
            // TODO: Type enforcement does not seem to be working
            // ports: context.resource.properties.container.ports
            ports: [
              {
                containerPort: containerPort
                name: 'http'
              }
            ]
          }
        ]
      }
    }
  }
}

resource service 'core/Service@v1' = {
  metadata: {
    name: resourceName
    labels: {
      app: applicationName
      resource: resourceName
    }
  }
  spec: {
    type: 'ClusterIP'
    selector: {
      app: applicationName
      resource: resourceName
    }
    ports: [
      {
        port: containerPort
      }
    ]
  }
}

output result object = {
  resources: [
    '/planes/kubernetes/local/namespaces/${service.metadata.namespace}/providers/core/Service/${service.metadata.name}'
    '/planes/kubernetes/local/namespaces/${deployment.metadata.namespace}/providers/apps/Deployment/${deployment.metadata.name}'
  ]
  values: {
    serviceName: resourceName
    servicePort: containerPort
  }
}
