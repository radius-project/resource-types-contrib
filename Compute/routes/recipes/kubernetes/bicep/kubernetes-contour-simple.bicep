@description('Radius-provided deployment context (resource properties and metadata).')
param context object

extension kubernetes with {
  namespace: context.runtime.kubernetes.namespace
  kubeConfig: ''
} as kubernetes

// Extract route information from context
var rules = context.resource.properties.rules
var hostnames = context.resource.properties.?hostnames ?? []
var resourceName = context.resource.name
var routeKind = context.resource.properties.?kind ?? 'HTTP'

// Validate that we can handle this route kind
var supportedKinds = ['HTTP', 'TLS']
var isSupported = contains(supportedKinds, routeKind)

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

// Create HTTPProxy for our routes (only for HTTP/TLS kinds)
resource httpProxy 'projectcontour.io/HTTPProxy@v1' = if (isSupported) {
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
    virtualhost: length(hostnames) > 0 ? {
      fqdn: hostnames[0]
    } : {
      fqdn: '${resourceName}.local'
    }
    routes: [
      for rule in rules: {
        conditions: [
          {
            prefix: rule.matches[0].?httpPath ?? '/'
          }
        ]
        services: [
          {
            // Create a predictable service name based on container name
            name: 'mock-${replace(rule.destinationContainer.containerName, '_', '-')}-service'
            port: 80
          }
        ]
      }
    ]
  }
  dependsOn: [
    contourInstaller
  ]
}

// Create mock services for each container referenced in rules
resource mockServices 'core/Service@v1' = [for rule in rules: {
  metadata: {
    name: 'mock-${replace(rule.destinationContainer.containerName, '_', '-')}-service'
    namespace: context.runtime.kubernetes.namespace
    labels: {
      'app': 'mock-backend'
      'mock-for': rule.destinationContainer.containerName
    }
  }
  spec: {
    selector: {
      'app': 'mock-backend'
    }
    ports: [
      {
        port: 80
        targetPort: 'http'
        name: 'http'
      }
    ]
    type: 'ClusterIP'
  }
}]

// Single deployment that serves as backend for all mock services
resource mockBackendDeployment 'apps/Deployment@v1' = {
  metadata: {
    name: 'mock-backend'
    namespace: context.runtime.kubernetes.namespace
    labels: {
      'app': 'mock-backend'
    }
  }
  spec: {
    replicas: 1
    selector: {
      matchLabels: {
        'app': 'mock-backend'
      }
    }
    template: {
      metadata: {
        labels: {
          'app': 'mock-backend'
        }
      }
      spec: {
        containers: [
          {
            name: 'mock-backend'
            image: 'gcr.io/google-containers/defaultbackend-amd64:1.4'
            ports: [
              {
                containerPort: 8080
                name: 'http'
              }
            ]
            env: [
              {
                name: 'PORT'
                value: '8080'
              }
            ]
          }
        ]
      }
    }
  }
}

// Generate mock service resource paths
var mockServicePaths = [for i in range(0, length(rules)): '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/core/Service/mock-${replace(rules[i].destinationContainer.containerName, '_', '-')}-service']

output result object = {
  values: {
    hostname: isSupported && length(hostnames) > 0 ? hostnames[0] : 'mock.local'
    routeCount: length(rules)
  }
  secrets: {}
  resources: concat(
    isSupported ? [
      '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/projectcontour.io/HTTPProxy/routes-${uniqueString(context.resource.id)}'
    ] : [],
    [
      '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/apps/Deployment/mock-backend'
    ],
    mockServicePaths
  )
}