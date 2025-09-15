@description('Radius-provided deployment context (resource properties and metadata).')
param context object

extension kubernetes with {
  namespace: context.runtime.kubernetes.namespace
  kubeConfig: ''
} as kubernetes

// Extract route information from context
var rules = context.resource.properties.rules
var hostnames = context.resource.properties.?hostnames ?? []
var routeKind = context.resource.properties.?kind ?? 'HTTP'
var resourceId = context.resource.id
var gatewayName = 'gateway-${uniqueString(resourceId)}'

// Create Gateway for routing
resource gateway 'gateway.networking.k8s.io/Gateway@v1' = {
  metadata: {
    name: gatewayName
    namespace: context.runtime.kubernetes.namespace
    labels: {
      'app.kubernetes.io/name': 'radius-gateway'
      'app.kubernetes.io/component': 'gateway'
      'app.kubernetes.io/part-of': 'radius'
    }
  }
  spec: {
    gatewayClassName: 'contour'
    listeners: [
      {
        name: 'http'
        port: 80
        protocol: 'HTTP'
        allowedRoutes: {
          namespaces: {
            from: 'Same'
          }
        }
      }
    ]
  }
}

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
  spec: {
    parentRefs: [
      {
        name: gatewayName
        namespace: context.runtime.kubernetes.namespace
      }
    ]
    hostnames: length(hostnames) > 0 ? hostnames : ['localhost']
    rules: [
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
            name: '${toLower(last(split(rule.destinationContainer.resourceId, '/')))}-${rule.destinationContainer.containerName}'
            port: 80
          }
        ]
      }
    ]
  }
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
  spec: {
    parentRefs: [
      {
        name: gatewayName
        namespace: context.runtime.kubernetes.namespace
      }
    ]
    hostnames: length(hostnames) > 0 ? hostnames : ['localhost']
    rules: [
      for rule in rules: {
        backendRefs: [
          {
            name: '${toLower(last(split(rule.destinationContainer.resourceId, '/')))}-${rule.destinationContainer.containerName}'
            port: 443
          }
        ]
      }
    ]
  }
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
        namespace: context.runtime.kubernetes.namespace
      }
    ]
    rules: [
      for rule in rules: {
        backendRefs: [
          {
            name: '${toLower(last(split(rule.destinationContainer.resourceId, '/')))}-${rule.destinationContainer.containerName}'
            port: 80
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
        namespace: context.runtime.kubernetes.namespace
      }
    ]
    rules: [
      for rule in rules: {
        backendRefs: [
          {
            name: '${toLower(last(split(rule.destinationContainer.resourceId, '/')))}-${rule.destinationContainer.containerName}'
            port: 80
          }
        ]
      }
    ]
  }
}

output result object = {
  values: {
    hostname: length(hostnames) > 0 ? hostnames[0] : 'localhost'
    routeCount: length(rules)
    routeKind: routeKind
    gatewayName: gatewayName
  }
  secrets: {}
  resources: concat([
    '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/Gateway/${gatewayName}'
  ], routeKind == 'HTTP' ? [
    '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/HTTPRoute/routes-${uniqueString(context.resource.id)}'
  ] : routeKind == 'TLS' ? [
    '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/TLSRoute/routes-${uniqueString(context.resource.id)}'
  ] : routeKind == 'TCP' ? [
    '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/TCPRoute/routes-${uniqueString(context.resource.id)}'
  ] : routeKind == 'UDP' ? [
    '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/UDPRoute/routes-${uniqueString(context.resource.id)}'
  ] : [])
}