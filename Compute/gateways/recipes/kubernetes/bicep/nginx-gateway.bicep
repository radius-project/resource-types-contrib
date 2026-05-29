@description('Radius-provided deployment context.')
param context object

extension kubernetes with {
  namespace: context.runtime.kubernetes.namespace
  kubeConfig: ''
} as kubernetes

var resourceName = context.resource.name
var properties = context.resource.properties
var gatewayClassName = properties.?gatewayClassName ?? 'nginx'
var listeners = properties.?listeners ?? [
  {
    name: 'http'
    protocol: 'HTTP'
    port: 80
    allowedRoutesFrom: 'Same'
  }
]
var environmentSegments = properties.environment != null ? split(string(properties.environment), '/') : []
var environmentLabel = length(environmentSegments) > 0 ? last(environmentSegments) : ''
var resourceSegments = split(string(context.resource.id), '/')
var resourceGroup = length(resourceSegments) > 4 ? resourceSegments[4] : ''
var resourceType = context.resource.?type ?? (length(resourceSegments) > 6 ? '${resourceSegments[5]}/${resourceSegments[6]}' : '')
var resourceTypeLabel = replace(resourceType, '/', '.')
var labels = {
  'radapp.io/resource': resourceName
  'radapp.io/environment': environmentLabel
  'radapp.io/application': context.application == null ? '' : context.application.name
  'radapp.io/resource-type': resourceTypeLabel
  'radapp.io/resource-group': resourceGroup
}

resource gateway 'gateway.networking.k8s.io/gateways@v1' = {
  metadata: {
    name: resourceName
    namespace: context.runtime.kubernetes.namespace
    labels: labels
  }
  spec: {
    gatewayClassName: gatewayClassName
    listeners: [
      for listener in listeners: union(
        {
          name: listener.name
          protocol: listener.protocol
          port: listener.port
          allowedRoutes: {
            namespaces: {
              from: listener.?allowedRoutesFrom ?? 'Same'
            }
          }
        },
        (listener.?hostname ?? '') != '' ? { hostname: listener.hostname } : {}
      )
    ]
  }
}

output result object = {
  resources: [
    '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/gateway.networking.k8s.io/Gateway/${gateway.name}'
  ]
  values: {
    gatewayName: gateway.name
    gatewayNamespace: context.runtime.kubernetes.namespace
  }
}
