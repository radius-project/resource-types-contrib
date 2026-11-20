@description('Radius target desired inputs and related delegating Routes.')
@secure()
param context object

@description('Name of an existing Azure Container Apps managed environment.')
param containerAppsEnvironmentName string

@description('Resource group containing the existing managed environment.')
param containerAppsEnvironmentResourceGroupName string = resourceGroup().name

@description('Region of the existing managed environment; must match its location.')
param containerAppsLocation string

@description('Expose TCP ingress outside the ACA environment. Requires a VNet-enabled environment and environment-wide unique exposed ports.')
param containerAppsExternalIngress bool = false

@description('Optional map of target TCP port to exposed TCP port, keyed by the target port number.')
param containerAppsExposedPorts object = {}

@description('Default CPU allocation per workload container, as a decimal string.')
param containerAppsDefaultCpu string = '0.25'

@description('Default memory allocation per workload container in MiB.')
@minValue(1)
param containerAppsDefaultMemoryInMib int = 512

var properties = context.resource.properties
var containers = items(properties.containers)
var incoming = context.resource.?incomingReferences ?? []
var regularContainers = filter(containers, container => container.value.?initContainer != true)
var rules = flatten(map(
  incoming,
  route =>
    map(route.properties.rules, rule => {
      routeId: route.id
      destination: rule.destinationContainer
      matches: rule.matches
    })
))
var declaredPorts = flatten(map(
  regularContainers,
  container =>
    map(items(container.value.?ports ?? {}), port => {
      containerName: container.key
      port: port.value.containerPort
      protocol: port.value.?protocol ?? 'TCP'
    })
))
var targetPorts = sort(union([], map(rules, rule => rule.destination.containerPort)), (left, right) => left < right)
var requestedExposedPorts = map(targetPorts, port => containerAppsExposedPorts[?string(port)] ?? port)
var exposedPorts = map(requestedExposedPorts, port => int(port))
var invalidRoutes = filter(
  incoming,
  route =>
    route.type != 'Radius.Compute/routes' || (route.properties.?kind ?? 'HTTP') != 'TCP' || !empty(route.properties.?hostnames ?? []) || empty(route.properties.rules) || length(union(
      [],
      map(
        route.properties.rules,
        rule => '${rule.destinationContainer.containerName}:${rule.destinationContainer.containerPort}'
      )
    )) != 1
)
var invalidRules = filter(
  rules,
  rule =>
    !empty(rule.matches) || toLower(rule.destination.resourceId) != toLower(context.resource.id) || empty(filter(
      declaredPorts,
      port =>
        port.containerName == rule.destination.containerName && port.port == rule.destination.containerPort && port.protocol == 'TCP'
    ))
)

var connections = context.resource.?connections ?? {}
var connectionDefinitions = properties.?connections ?? {}
var excludedProperties = ['recipe', 'status', 'provisioningState', 'resourceProvisioning', 'properties', 'secrets']
var activeConnections = filter(
  items(connections),
  connection => connectionDefinitions[?connection.key].?disableDefaultEnvVars != true
)
var invalidConnections = filter(
  activeConnections,
  connection => connection.value.?type == 'Radius.Security/secrets' || !empty(connection.value.?secrets ?? {})
)
var connectionEnv = reduce(
  activeConnections,
  {},
  (acc, connection) =>
    union(
      acc,
      reduce(
        filter(
          items(union(connection.value, connection.value.?properties ?? {})),
          property => !contains(excludedProperties, property.key)
        ),
        {},
        (env, property) =>
          union(env, {
            '${toUpper('CONNECTION_${connection.key}_${property.key}')}': string(property.value)
          })
      )
    )
)
var invalidContainers = filter(
  containers,
  container =>
    !empty(container.value.?workingDir ?? '') || !empty(container.value.?volumeMounts ?? []) || container.value.?readinessProbe != null || container.value.?livenessProbe != null || !empty(filter(
      items(container.value.?env ?? {}),
      env => env.value.?valueFrom != null || env.value.?value == null
    )) || (container.value.?resources.?requests.?cpu != null && container.value.?resources.?limits.?cpu != null && json(string(container.value.?resources.?requests.?cpu ?? '0')) != json(string(container.value.?resources.?limits.?cpu ?? '0'))) || (container.value.?resources.?requests.?memoryInMib != null && container.value.?resources.?limits.?memoryInMib != null && container.value.resources.requests.memoryInMib != container.value.resources.limits.memoryInMib)
)
var unsupportedWorkload = !empty(properties.?volumes ?? {}) || !empty(properties.?extensions ?? {}) || !empty(properties.?platformOptions ?? {}) || properties.?autoScaling != null || (properties.?restartPolicy ?? 'Always') != 'Always'
var validPorts = length(targetPorts) <= 6 && length(union([], exposedPorts)) == length(exposedPorts) && empty(filter(requestedExposedPorts, port => string(port) != string(int(port)))) && empty(filter(
  concat(targetPorts, exposedPorts),
  port => port < 1 || port > 65535 || port == 36985
)) && empty(filter(
  exposedPorts,
  port => containerAppsExternalIngress && (port == 80 || port == 443)
)) && empty(filter(
  declaredPorts,
  port =>
    length(union([], map(filter(declaredPorts, other => other.port == port.port), other => other.containerName))) > 1
)) && empty(filter(declaredPorts, port => port.protocol != 'TCP'))
var validation = empty(invalidRoutes) && empty(invalidRules) && validPorts && !empty(regularContainers) && length(union(
  [],
  map(containers, container => toLower(container.key))
)) == length(containers) && empty(invalidContainers) && empty(invalidConnections) && !unsupportedWorkload && (properties.?replicas ?? 1) >= 1 && empty(filter(
  allocations,
  allocation => int(allocation.memory) <= 0 || int(allocation.memory) % 256 != 0
))
var appName = validation
  ? 'aca-${uniqueString(toLower(context.resource.id))}'
  : fail('ACA TCP recipe: require unconditional TCP routes to one declared workload/port per route, at most six unique ports, no shared workload ports, valid exposed ports, and supported workload inputs. HTTP/TLS/UDP, probes, workingDir, volumes, extensions, platformOptions, autoscaling and secret references are unsupported; requests and limits must agree when both are set; memory must be a positive multiple of 256 MiB.')
var allocations = map(containers, container => {
  cpu: container.value.?resources.?limits.?cpu ?? container.value.?resources.?requests.?cpu ?? containerAppsDefaultCpu
  memory: container.value.?resources.?limits.?memoryInMib ?? container.value.?resources.?requests.?memoryInMib ?? containerAppsDefaultMemoryInMib
})
var workload = map(containers, (container, index) => {
  name: toLower(container.key)
  image: container.value.image
  command: container.value.?command ?? []
  args: container.value.?args ?? []
  env: map(
    items(union(
      connectionEnv,
      reduce(
        items(container.value.?env ?? {}),
        {},
        (acc, env) =>
          union(acc, {
            '${env.key}': env.value.value
          })
      )
    )),
    env => {
      name: env.key
      value: env.value
    }
  )
  resources: {
    cpu: json(string(allocations[index].cpu))
    memory: '${int(allocations[index].memory) / 1024}.${padLeft(string(int(allocations[index].memory) % 1024 * 100 / 1024), 2, '0')}Gi'
  }
})

resource app 'Microsoft.App/containerApps@2025-07-01' = {
  name: appName
  location: containerAppsLocation
  tags: {
    'radapp.io-resource': context.resource.name
  }
  properties: {
    managedEnvironmentId: resourceId(
      containerAppsEnvironmentResourceGroupName,
      'Microsoft.App/managedEnvironments',
      containerAppsEnvironmentName
    )
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: empty(targetPorts)
        ? null
        : {
            external: containerAppsExternalIngress
            transport: 'tcp'
            targetPort: targetPorts[0]
            exposedPort: exposedPorts[0]
            additionalPortMappings: map(skip(targetPorts, 1), (port, index) => {
              external: containerAppsExternalIngress
              targetPort: port
              exposedPort: exposedPorts[index + 1]
            })
            traffic: [{ latestRevision: true, weight: 100 }]
          }
    }
    template: {
      containers: filter(workload, (_, index) => containers[index].value.?initContainer != true)
      initContainers: filter(workload, (_, index) => containers[index].value.?initContainer == true)
      scale: {
        minReplicas: properties.?replicas ?? 1
        maxReplicas: properties.?replicas ?? 1
      }
    }
  }
}

output result object = {
  values: {
    hosts: reduce(
      filter(
        regularContainers,
        container => !empty(filter(rules, rule => rule.destination.containerName == container.key))
      ),
      {},
      (acc, container) =>
        union(acc, {
          '${container.key}': containerAppsExternalIngress ? app.properties.configuration.ingress.fqdn : app.name
        })
    )
  }
  delegatedOutputs: map(incoming, route => {
    id: route.id
    revision: route.revision
    values: {
      listener: {
        hostname: containerAppsExternalIngress ? app.properties.configuration.ingress.fqdn : app.name
        port: exposedPorts[indexOf(
          targetPorts,
          min(map(route.properties.rules, rule => rule.destinationContainer.containerPort))
        )]
        protocol: 'TCP'
      }
    }
  })
}
