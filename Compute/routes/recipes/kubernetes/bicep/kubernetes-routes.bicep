@description('Radius-provided deployment context.')
param context object

@description('Name of the Gateway resource to attach routes to. Must be provided by the user.')
param gatewayName string

@description('Namespace where the Gateway resource is located. Must be provided by the user.')
param gatewayNamespace string

extension kubernetes with {
  namespace: context.runtime.kubernetes.namespace
  kubeConfig: ''
} as kubernetes

// Extract route information from context
var resourceName = context.resource.name
var rules = context.resource.properties.rules
var hostnames = context.resource.properties.?hostnames ?? []
var routeKind = context.resource.properties.?kind ?? 'HTTP'
var environmentSegments = context.resource.properties.environment != null ? split(string(context.resource.properties.environment), '/') : []
var environmentLabel = length(environmentSegments) > 0 ? last(environmentSegments) : ''
var resourceSegments = split(string(context.resource.id), '/')
var resourceGroup = length(resourceSegments) > 4 ? resourceSegments[4] : ''
var resourceType = context.resource.?type ?? (length(resourceSegments) > 6 ? '${resourceSegments[5]}/${resourceSegments[6]}' : '')
var resourceTypeLabel = replace(resourceType, '/', '.')

// Labels
var labels = {
  'radapp.io/resource': resourceName
  'radapp.io/environment': environmentLabel
  'radapp.io/application': context.application == null ? '' : context.application.name
  'radapp.io/resource-type': resourceTypeLabel
  'radapp.io/resource-group': resourceGroup
}


// Create HTTPRoute for HTTP routing using Gateway API
resource httpRoute 'gateway.networking.k8s.io/HTTPRoute@v1' = if (routeKind == 'HTTP') {
  metadata: {
    name: 'routes-${uniqueString(context.resource.id)}'
    namespace: context.runtime.kubernetes.namespace
    labels: labels
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
    labels: labels
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
    labels: labels
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
            name: toLower(
              (rule.destinationContainer.?containerName ?? '') != ''
                ? '${last(split(rule.destinationContainer.resourceId, '/'))}-${rule.destinationContainer.containerName}'
                : last(split(rule.destinationContainer.resourceId, '/'))
            )
            port: rule.destinationContainer.containerPort
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
    labels: labels
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
            name: toLower(
              (rule.destinationContainer.?containerName ?? '') != ''
                ? '${last(split(rule.destinationContainer.resourceId, '/'))}-${rule.destinationContainer.containerName}'
                : last(split(rule.destinationContainer.resourceId, '/'))
            )
            port: rule.destinationContainer.containerPort
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
        name: toLower(
          (rule.destinationContainer.?containerName ?? '') != ''
            ? '${last(split(rule.destinationContainer.resourceId, '/'))}-${rule.destinationContainer.containerName}'
            : last(split(rule.destinationContainer.resourceId, '/'))
        )
        port: rule.destinationContainer.containerPort
      }
    ]
  }
]

// Build TLS rules
var tlsRules = [
  for rule in rules: {
    backendRefs: [
      {
        name: toLower(
          (rule.destinationContainer.?containerName ?? '') != ''
            ? '${last(split(rule.destinationContainer.resourceId, '/'))}-${rule.destinationContainer.containerName}'
            : last(split(rule.destinationContainer.resourceId, '/'))
        )
        port: rule.destinationContainer.containerPort
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
