@description('Radius-provided deployment context (resource properties and metadata).')
param context object

extension kubernetes with {
  namespace: context.runtime.kubernetes.namespace
  kubeConfig: ''
} as kubernetes

// Extract route information from context
var routes = context.resource.properties.routes
var resourceName = context.resource.name

// Install Contour using the standard quickstart YAML
// This creates a minimal Contour installation
resource contourNamespace 'core/Namespace@v1' = {
  metadata: {
    name: 'projectcontour'
  }
}

// Apply Contour quickstart manifests via Job
resource contourInstaller 'batch/Job@v1' = {
  metadata: {
    name: 'install-contour-${uniqueString(context.resource.id)}'
    namespace: context.runtime.kubernetes.namespace
  }
  spec: {
    template: {
      spec: {
        restartPolicy: 'OnFailure'
        containers: [
          {
            name: 'kubectl'
            image: 'bitnami/kubectl:latest'
            command: [
              'sh'
              '-c'
              'kubectl apply -f https://projectcontour.io/quickstart/contour.yaml || true'
            ]
          }
        ]
        serviceAccountName: 'contour-installer'
      }
    }
    backoffLimit: 3
  }
  dependsOn: [
    contourNamespace
    contourInstallerSA
    contourInstallerBinding
  ]
}

// ServiceAccount for installer
resource contourInstallerSA 'core/ServiceAccount@v1' = {
  metadata: {
    name: 'contour-installer'
    namespace: context.runtime.kubernetes.namespace
  }
}

// ClusterRoleBinding for installer
resource contourInstallerBinding 'rbac.authorization.k8s.io/ClusterRoleBinding@v1' = {
  metadata: {
    name: 'contour-installer-${uniqueString(context.resource.id)}'
  }
  roleRef: {
    apiGroup: 'rbac.authorization.k8s.io'
    kind: 'ClusterRole'
    name: 'cluster-admin'
  }
  subjects: [
    {
      kind: 'ServiceAccount'
      name: contourInstallerSA.metadata.name
      namespace: context.runtime.kubernetes.namespace
    }
  ]
}

// Create HTTPProxy for our routes
resource httpProxy 'projectcontour.io/HTTPProxy@v1' = {
  metadata: {
    name: 'routes-${uniqueString(context.resource.id)}'
    namespace: context.runtime.kubernetes.namespace
    labels: {
      'app': 'radius-routes'
      'radius.resource': context.resource.name
      'radius.resourceType': context.resource.type
      'radius.environment': context.resource.properties.environment
    }
  }
  spec: {
    virtualhost: {
      fqdn: context.resource.properties.hostname ?? '${resourceName}.local'
    }
    routes: [
      for route in routes: {
        conditions: [
          {
            prefix: route.path ?? '/'
          }
        ]
        services: route.nextHopType == 'VirtualAppliance' ? [
          {
            name: route.serviceName ?? 'default-backend'
            port: int(route.port ?? 80)
          }
        ] : []
      }
    ]
  }
  dependsOn: [
    contourInstaller
  ]
}

// Simple default backend service
resource defaultBackendService 'core/Service@v1' = {
  metadata: {
    name: 'default-backend'
    namespace: context.runtime.kubernetes.namespace
  }
  spec: {
    selector: {
      app: 'default-backend'
    }
    ports: [
      {
        port: 80
        targetPort: 8080
      }
    ]
  }
}

resource defaultBackendDeployment 'apps/Deployment@v1' = {
  metadata: {
    name: 'default-backend'
    namespace: context.runtime.kubernetes.namespace
  }
  spec: {
    replicas: 1
    selector: {
      matchLabels: {
        app: 'default-backend'
      }
    }
    template: {
      metadata: {
        labels: {
          app: 'default-backend'
        }
      }
      spec: {
        containers: [
          {
            name: 'backend'
            image: 'gcr.io/google-containers/defaultbackend-amd64:1.4'
            ports: [
              {
                containerPort: 8080
              }
            ]
          }
        ]
      }
    }
  }
}

output result object = {
  values: {
    hostname: httpProxy.spec.virtualhost.fqdn
    routeCount: length(routes)
  }
  secrets: {}
  resources: [
    '/planes/kubernetes/local/namespaces/${httpProxy.metadata.namespace}/providers/projectcontour.io/HTTPProxy/${httpProxy.metadata.name}'
    '/planes/kubernetes/local/namespaces/${defaultBackendService.metadata.namespace}/providers/core/Service/${defaultBackendService.metadata.name}'
    '/planes/kubernetes/local/namespaces/${defaultBackendDeployment.metadata.namespace}/providers/apps/Deployment/${defaultBackendDeployment.metadata.name}'
  ]
}