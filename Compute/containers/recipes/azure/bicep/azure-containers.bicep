@description('Radius context object passed into the recipe.')
param context object

var resourceName = context.resource.name
var resourceProperties = context.resource.properties ?? {}
var containerItems = items(resourceProperties.containers ?? {})

// ---------------------------------------------------------------------------
// Init containers are not supported by ACI; exclude them.
// ---------------------------------------------------------------------------
var workloadContainers = reduce(containerItems, [], (acc, item) =>
  !(item.value.?initContainer ?? false) ? concat(acc, [item]) : acc)

// ---------------------------------------------------------------------------
// Connection environment variables.
// Secrets connections (Radius.Security/secrets) are skipped because ACI has no
// equivalent of Kubernetes secretRef injection.  When an Azure Secrets recipe
// is available this section can be extended to pull values from Azure Key Vault
// references instead.
// ---------------------------------------------------------------------------
var resourceConnections = context.resource.connections ?? {}
var connectionDefinitions = resourceProperties.connections ?? {}
var excludedProperties = ['recipe', 'status', 'provisioningState']

var isSecretsConnection = reduce(items(connectionDefinitions), {}, (acc, conn) => union(acc, {
  '${conn.key}': contains(string(conn.value.?source ?? ''), 'Radius.Security/secrets')
}))

var connectionEnvVars = reduce(items(resourceConnections), [], (acc, conn) =>
  !isSecretsConnection[conn.key] && connectionDefinitions[conn.key].?disableDefaultEnvVars != true
    ? concat(acc,
        reduce(items(conn.value ?? {}), [], (envAcc, prop) =>
          contains(excludedProperties, prop.key)
            ? envAcc
            : concat(envAcc, [{
                name: toUpper('CONNECTION_${conn.key}_${prop.key}')
                value: string(prop.value)
              }])
        )
      )
    : acc)

// ---------------------------------------------------------------------------
// ACI container definitions.
//
// CPU / memory:  ACI requires cpu (float, vCPUs) and memoryInGB (float).
// The Radius schema stores cpu as a string ('0.25') and memoryInMib as an
// integer.  Bicep has no string-to-float function, so the recipe uses the ACI
// minimums (0.5 vCPU / 0.5 GB) as defaults.  For workloads that need higher
// limits pass the values through platformOptions and read them here.
// ---------------------------------------------------------------------------
var aciContainers = reduce(workloadContainers, [], (acc, item) => concat(acc, [union(
  {
    name: item.key
    image: item.value.image
    resources: {
      requests: {
        cpu: json('0.5')
        memoryInGB: json('0.5')
      }
    }
  },
  // Ports
  contains(item.value, 'ports') ? {
    ports: reduce(items(item.value.ports), [], (portAcc, port) => concat(portAcc, [{
      containerPort: port.value.containerPort
      protocol: port.value.?protocol ?? 'TCP'
    }]))
  } : {},
  // Environment variables: container-defined vars merged with connection-derived vars
  (contains(item.value, 'env') || length(connectionEnvVars) > 0) ? {
    environmentVariables: concat(
      reduce(items(item.value.?env ?? {}), [], (envAcc, envItem) => concat(envAcc, [union(
        { name: envItem.key },
        contains(envItem.value, 'value') ? { value: envItem.value.value } : { value: '' }
      )])),
      connectionEnvVars
    )
  } : {},
  // Command: ACI has a single command array; concatenate Radius command + args
  contains(item.value, 'command') ? {
    command: concat(item.value.command, item.value.?args ?? [])
  } : {}
)]))

// ---------------------------------------------------------------------------
// Container group
// ---------------------------------------------------------------------------
resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: resourceName
  location: resourceGroup().location
  properties: {
    containers: aciContainers
    osType: 'Linux'
    restartPolicy: resourceProperties.?restartPolicy ?? 'Always'
  }
}

output result object = {
  resources: [containerGroup.id]
}
