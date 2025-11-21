@description('Radius-provided deployment context.')
param context object

@description('Name of the Gateway resource to attach routes to. Can be configured per environment or recipe.')
param gatewayName string = 'default-gateway'

@description('Namespace where the Gateway resource is located. Defaults to the same namespace as the route.')
param gatewayNamespace string = context.runtime.kubernetes.namespace

extension kubernetes with {
  namespace: context.runtime.kubernetes.namespace
  kubeConfig: ''
} as kubernetes

// Extract route information from context
var rules = context.resource.properties.rules
var hostnames = context.resource.properties.?hostnames ?? []
var routeKind = context.resource.properties.?kind ?? 'HTTP'

// Create HTTPRoute for HTTP routing using Gateway API
resource httpRoute 'gateway.networking.k8s.io/HTTPRoute@v1' = if (routeKind == 'HTTP') {
  metadata: {
    name: 'routes-${uniqueString(context.resource.id)}'
    namespace: context.runtime.kubernetes.namespace
    labels: {
      'app.kubernetes.io/name': 'radius-routes'
      'app.kubernetes.io/component': 'httproute'
      'app.kubernetes.io/part-of': 'radius'
    }
  }
  spec: union(
    {
      parentRefs: [
        {
          name: gatewayName
          namespace: gatewayNamespace
        }
      ]
      rules: httpRules
    },
    length(hostnames) > 0 ? { hostnames: hostnames } : {}
  )
}

// Create TLSRoute for TLS routing using Gateway API
resource tlsRoute 'gateway.networking.k8s.io/TLSRoute@v1alpha2' = if (routeKind == 'TLS') {
  metadata: {
    name: 'routes-${uniqueString(context.resource.id)}'
    namespace: context.runtime.kubernetes.namespace
    labels: {
      'app.kubernetes.io/name': 'radius-routes'
      'app.kubernetes.io/component': 'tlsroute'
      'app.kubernetes.io/part-of': 'radius'
    }
  }
  spec: union(
    {
      parentRefs: [
        {
          name: gatewayName
          namespace: gatewayNamespace
        }
      ]
      rules: tlsRules
    },
    length(hostnames) > 0 ? { hostnames: hostnames } : {}
  )
}

// Create TCPRoute for TCP routing using Gateway API
resource tcpRoute 'gateway.networking.k8s.io/TCPRoute@v1alpha2' = if (routeKind == 'TCP') {
  metadata: {
    name: 'routes-${uniqueString(context.resource.id)}'
    namespace: context.runtime.kubernetes.namespace
    labels: {
      'app.kubernetes.io/name': 'radius-routes'
      'app.kubernetes.io/component': 'tcproute'
      'app.kubernetes.io/part-of': 'radius'
    }
  }
  spec: {
    parentRefs: [
      {
        name: gatewayName
        namespace: gatewayNamespace
      }
    ]
    rules: [
      for rule in rules: {
        backendRefs: [
          {
            name: toLower(last(split(rule.destinationContainer.resourceId, '/')))
            port: rule.destinationContainer.?containerPort ?? 80
          }
        ]
      }
    ]
  }
}

// Create UDPRoute for UDP routing using Gateway API
resource udpRoute 'gateway.networking.k8s.io/UDPRoute@v1alpha2' = if (routeKind == 'UDP') {
  metadata: {
    name: 'routes-${uniqueString(context.resource.id)}'
    namespace: context.runtime.kubernetes.namespace
    labels: {
      'app.kubernetes.io/name': 'radius-routes'
      'app.kubernetes.io/component': 'udproute'
      'app.kubernetes.io/part-of': 'radius'
    }
  }
  spec: {
    parentRefs: [
      {
        name: gatewayName
        namespace: gatewayNamespace
      }
    ]
    rules: [
      for rule in rules: {
        backendRefs: [
          {
            name: toLower(last(split(rule.destinationContainer.resourceId, '/')))
            port: rule.destinationContainer.?containerPort ?? 80
          }
        ]
      }
    ]
  }
}

// Build HTTP rules
var httpRules = [
  for rule in rules: {
    matches: [
      {
        path: {
          type: 'PathPrefix'
          value: rule.matches[0].?httpPath ?? '/'
        }
      }
    ]
    backendRefs: [
      {
        name: toLower(last(split(rule.destinationContainer.resourceId, '/')))
        port: rule.destinationContainer.?containerPort ?? 80
      }
    ]
  }
]

// Build TLS rules
var tlsRules = [
  for rule in rules: {
    backendRefs: [
      {
        name: toLower(last(split(rule.destinationContainer.resourceId, '/')))
        port: rule.destinationContainer.?containerPort ?? 443
      }
    ]
  }
]

output result object = {
  resources: routeKind == 'HTTP' ? [
    '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/HTTPRoute/routes-${uniqueString(context.resource.id)}'
  ] : routeKind == 'TLS' ? [
    '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/TLSRoute/routes-${uniqueString(context.resource.id)}'
  ] : routeKind == 'TCP' ? [
    '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/TCPRoute/routes-${uniqueString(context.resource.id)}'
  ] : routeKind == 'UDP' ? [
    '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/UDPRoute/routes-${uniqueString(context.resource.id)}'
  ] : []
}
