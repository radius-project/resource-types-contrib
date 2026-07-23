@description('NGroups parameter name')
@maxLength(63)
param nGroupsParamName string = 'ngroups-${uniqueString(resourceGroup().id)}'

@description('Container Group Profile name')
@maxLength(63)
param containerGroupProfileName string = 'cgp-${uniqueString(resourceGroup().id)}'

@description('Load Balancer name')
@maxLength(64)
param loadBalancerName string = 'slb-${uniqueString(resourceGroup().id)}'

@description('Backend Address Pool name')
@maxLength(64)
param backendAddressPoolName string = 'bepool_1'

@description('Virtual Network name')
@maxLength(64)
param vnetName string = 'vnet-${uniqueString(resourceGroup().id)}'

@description('Subnet name')
@maxLength(64)
param subnetName string = 'subnet_1'

@description('Network Security Group name')
@maxLength(64)
param networkSecurityGroupName string = 'nsg-${uniqueString(resourceGroup().id)}'

@description('Inbound Public IP name')
@maxLength(64)
param inboundPublicIPName string = 'inboundPIP-${uniqueString(resourceGroup().id)}'

@description('Outbound Public IP name')
@maxLength(64)
param outboundPublicIPName string = 'outboundPIP-${uniqueString(resourceGroup().id)}'

@description('NAT Gateway name')
param natGatewayName string = 'natgw-${uniqueString(resourceGroup().id)}'

@description('Frontend IP name')
@maxLength(64)
param frontendIPName string = 'loadBalancerFrontend'

@description('HTTP Rule name')
@maxLength(64)
param httpRuleName string = 'httpRule'

@description('Virtual Network address prefix')
@maxLength(64)
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Subnet address prefix')
@maxLength(64)
param subnetAddressPrefix string = '10.0.1.0/24'

@description('Desired container count')
// ACI NGroups scale settings are recipe parameters; Radius resource-level
// properties context.resource.properties.replicas and autoScaling are not supported for this recipe.
param desiredCount int = 3

@description('Maintain desired count')
param maintainDesiredCount bool = true

@description('When false, ignores context.resource.properties.platformOptions. Defaults to true.')
param allowPlatformOptions bool = true

@description('Enable DDoS protection (limit: 1 plan per subscription per region)')
param enableDdosProtection bool = false

@description('Name of an existing DDoS protection plan (required when enableDdosProtection is true)')
param ddosProtectionPlanName string = 'ddosProtectionPlan'

@description('Radius ACI Container Context')
param context object

// Variables
var cgProfileName = containerGroupProfileName
var nGroupsName = nGroupsParamName
var resourceProperties = context.resource.properties ?? {}
var hasPlatformOptions = resourceProperties.?platformOptions != null
// ACI does not support Radius extensions.daprSidecar; this recipe intentionally
// ignores any Dapr sidecar configuration provided via context.resource.properties.extensions.
var resourceVolumes = resourceProperties.?volumes ?? {}
var resolvedConnections = context.resource.?connections ?? {}

// ---------------------------------------------------------------------------
// Secrets connection – consume the UAI created by the Key Vault secrets recipe
// No role assignment is created here – RBAC is owned by the secrets recipe,
// which already grants "Key Vault Administrator" to the UAI on the vault.
//
// Radius wires connection data with full resource structure:
//   context.resource.connections.<name>.properties.status.computedValues.<key>
//   context.resource.connections.<name>.properties.status.secrets.<key>.Value
// ---------------------------------------------------------------------------
var secretsConn = contains(context.resource, 'connections') && contains(context.resource.connections, 'secrets') ? context.resource.connections.secrets : {}
var secretsUaiId = string(secretsConn.?properties.?status.?computedValues.?userAssignedIdentityId ?? '')
var secretsUaiClientId = string(secretsConn.?properties.?status.?computedValues.?userAssignedIdentityClientId ?? '')
var secretsKeyVaultUri = string(secretsConn.?properties.?status.?computedValues.?keyVaultUri ?? '')

// Azure SDK env vars injected when a secrets connection is active.
// AZURE_CLIENT_ID lets ManagedIdentityCredential pick the correct UAI.
// AZURE_KEYVAULT_URI tells the app which vault to query.
var secretsEnvVars = secretsUaiClientId != '' ? [
  { name: 'AZURE_CLIENT_ID', value: secretsUaiClientId }
  { name: 'AZURE_KEYVAULT_URI', value: secretsKeyVaultUri }
] : []

// Platform options are applied only when allowPlatformOptions is true.
// When allowPlatformOptions is false, provided platformOptions are ignored.
// Location is always resourceGroup().location; platformOptions.location is not supported by this recipe.
var platformOptions = allowPlatformOptions && hasPlatformOptions ? resourceProperties.?platformOptions ?? {} : {}
var effectiveLocation = resourceGroup().location
var aciSku = contains(platformOptions, 'sku') && platformOptions.sku != null ? string(platformOptions.sku) : 'Standard'
var isConfidential = toLower(aciSku) == 'confidential'
var zones = isConfidential ? [] : []
var ccePolicy = contains(platformOptions, 'confidentialComputeProperties') && contains(platformOptions.confidentialComputeProperties, 'ccePolicy') ? string(platformOptions.confidentialComputeProperties.ccePolicy) : ''

// Extract container items from context
var containerItems = items(context.resource.properties.?containers ?? {})
// Containers with initContainer: true are placed in the ACI initContainers[] array;
// regular containers go into the containers[] array.
var regularContainerItems = filter(containerItems, item => item.value.?initContainer != true)
var initContainerItems = filter(containerItems, item => item.value.?initContainer == true)

// Derive the first regular container's first exposed port (used for ipAddress and LB rules)
var firstContainerPorts = length(regularContainerItems) > 0 && contains(regularContainerItems[0].value, 'ports') ? items(regularContainerItems[0].value.ports) : []
var containerConnectionPort = length(firstContainerPorts) > 0 ? firstContainerPorts[0].value.containerPort : 80

// Find the first regular container with a readiness probe for load balancer probe reference
var firstContainerWithReadinessProbe = length(filter(regularContainerItems, item => contains(item.value, 'readinessProbe') && item.value.readinessProbe != null)) > 0 
  ? filter(regularContainerItems, item => contains(item.value, 'readinessProbe') && item.value.readinessProbe != null)[0]
  : null
var readinessProbeContainerName = firstContainerWithReadinessProbe.?key ?? ''

// Extract connection data from linked resources (merged with resource properties)
var resourceConnections = context.resource.?connections ?? {}
var connectionDefinitions = context.resource.properties.?connections ?? {}

// Properties to exclude from connection environment variables
var excludedProperties = ['recipe', 'status', 'provisioningState']

// Build environment variables from ALL connections (including secrets) when not explicitly disabled.
// Unlike K8s which uses envFrom.secretRef for secrets connections, ACI does not support that mechanism.
// Instead, secrets connection metadata (keyVaultUri, UAI client ID, etc.) is injected as plain env vars
// so the container can use the Azure SDK with ManagedIdentityCredential to fetch secrets at runtime.
var connectionEnvVars = reduce(items(resourceConnections), [], (acc, conn) => 
  connectionDefinitions[conn.key].?disableDefaultEnvVars != true
    ? concat(acc, 
        // Add resource properties directly from connection (excluding metadata properties)
        reduce(items(conn.value ?? {}), [], (envAcc, prop) => 
          contains(excludedProperties, prop.key)
            ? envAcc 
            : concat(envAcc, [{
                name: toUpper('CONNECTION_${conn.key}_${prop.key}')
                value: string(prop.value)
              }])
        )
      )
    : acc
)

// Build ACI volumes - similar pattern to kubernetes-containers.bicep but
// for ACI we resolve storage account details from computedValues/secrets
// instead of PVC name, because ACI needs explicit Azure File credentials.
// Note: Kubernetes-style `secretName` volumes are not supported in ACI.
// ACI does not support mounting secrets from external stores as volumes.
// Instead, secrets are typically provided via secure environment variables (AZURE_CLIENT_ID, AZURE_KEYVAULT_URI)
// or accessed at runtime (e.g., via managed identity + Azure Key Vault).
var volumeItems = filter(items(resourceVolumes), vol => contains(vol.value, 'persistentVolume') || contains(vol.value, 'emptyDir'))
var aciVolumeNames = map(volumeItems, vol => vol.key)
var aciVolumes = reduce(volumeItems, [], (acc, vol) => concat(acc, [
  union(
    { name: vol.key },
    contains(vol.value, 'persistentVolume') && contains(resolvedConnections, vol.key) ? {
      azureFile: {
        shareName: string(resolvedConnections[vol.key].?properties.?status.?computedValues.?shareName ?? '')
        storageAccountName: string(resolvedConnections[vol.key].?properties.?status.?computedValues.?storageAccountName ?? '')
        storageAccountKey: string(resolvedConnections[vol.key].?properties.?status.?secrets.?storageAccountKey.?Value ?? '')
        readOnly: string(vol.value.persistentVolume.?accessMode ?? '') == 'ReadOnlyMany'
      }
    } : {},
    contains(vol.value, 'emptyDir') ? { emptyDir: {} } : {}
  )
]))

// DDoS Protection Plan — use existing if already present (limit: 1 per subscription per region)
resource ddosProtectionPlan 'Microsoft.Network/ddosProtectionPlans@2022-07-01' existing = if (enableDdosProtection) {
  name: ddosProtectionPlanName
}

// Network Security Group
resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2022-07-01' = {
  name: networkSecurityGroupName
  location: effectiveLocation
  properties: {
    securityRules: [
      {
        name: 'AllowHTTPInbound'
        properties: {
          access: 'Allow'
          description: 'Allow Internet traffic on port range'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '80-331'
          ]
          direction: 'Inbound'
          protocol: '*'
          priority: 100
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
        }
      }
    ]
  }
}

// Inbound Public IP
resource inboundPublicIP 'Microsoft.Network/publicIPAddresses@2022-07-01' = {
  name: inboundPublicIPName
  location: effectiveLocation
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
    ipTags: []
  }
}

// Outbound Public IP
resource outboundPublicIP 'Microsoft.Network/publicIPAddresses@2022-07-01' = {
  name: outboundPublicIPName
  location: effectiveLocation
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
    ipTags: []
  }
}

// NAT Gateway
resource natGateway 'Microsoft.Network/natGateways@2022-07-01' = {
  name: natGatewayName
  location: effectiveLocation
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: outboundPublicIP.id
      }
    ]
  }
}

// Virtual Network
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2022-07-01' = {
  name: vnetName
  location: effectiveLocation
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
          serviceEndpoints: []
          delegations: [
            {
              name: 'Microsoft.ContainerInstance.containerGroups'
              id: '${resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)}/delegations/Microsoft.ContainerInstance.containerGroups'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
              type: 'Microsoft.Network/virtualNetworks/subnets/delegations'
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
          natGateway: {
            id: natGateway.id
          }
        }
        type: 'Microsoft.Network/virtualNetworks/subnets'
      }
    ]
    virtualNetworkPeerings: []
    enableDdosProtection: enableDdosProtection
    ddosProtectionPlan: enableDdosProtection ? {
      id: ddosProtectionPlan.id
    } : null
  }
}

// Load Balancer
resource loadBalancer 'Microsoft.Network/loadBalancers@2022-07-01' = {
  name: loadBalancerName
  location: effectiveLocation
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        properties: {
          publicIPAddress: {
            id: inboundPublicIP.id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
        name: frontendIPName
      }
    ]
    backendAddressPools: [
      {
        name: backendAddressPoolName
        id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, backendAddressPoolName)
        properties: {
          loadBalancerBackendAddresses: []
        }
      }
    ]
    // Only regular containers have readiness/liveness probes; init containers are excluded.
    probes: reduce(regularContainerItems, [], (acc, item) => concat(acc, 
      union(
        // Add readiness probe if exists for this container
        contains(item.value, 'readinessProbe') && item.value.readinessProbe != null ? [{
          name: '${item.key}-readinessProbe'
          properties: union(
            {
              protocol: item.value.readinessProbe.?httpGet != null
                ? (toLower(item.value.readinessProbe.httpGet.?scheme ?? 'http') == 'https' ? 'Https' : 'Http')
                : 'Tcp'
              port: item.value.readinessProbe.?httpGet.?port ?? item.value.readinessProbe.?tcpSocket.?port ?? 80
              intervalInSeconds: item.value.readinessProbe.?periodSeconds ?? 5
              numberOfProbes: item.value.readinessProbe.?failureThreshold ?? 3
              probeThreshold: item.value.readinessProbe.?successThreshold ?? 1
            },
            item.value.readinessProbe.?httpGet != null ? {
              requestPath: item.value.readinessProbe.httpGet.path
            } : {}
          )
        }] : [],
        // Add liveness probe if exists for this container
        contains(item.value, 'livenessProbe') && item.value.livenessProbe != null ? [{
          name: '${item.key}-livenessProbe'
          properties: union(
            {
              protocol: item.value.livenessProbe.?httpGet != null
                ? (toLower(item.value.livenessProbe.httpGet.?scheme ?? 'http') == 'https' ? 'Https' : 'Http')
                : 'Tcp'
              port: item.value.livenessProbe.?httpGet.?port ?? item.value.livenessProbe.?tcpSocket.?port ?? 80
              intervalInSeconds: item.value.livenessProbe.?periodSeconds ?? 10
              numberOfProbes: item.value.livenessProbe.?failureThreshold ?? 3
              probeThreshold: item.value.livenessProbe.?successThreshold ?? 1
            },
            item.value.livenessProbe.?httpGet != null ? {
              requestPath: item.value.livenessProbe.httpGet.path
            } : {}
          )
        }] : []
      )
    ))
    loadBalancingRules: [
      {
        name: httpRuleName
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, frontendIPName)
          }
          frontendPort: containerConnectionPort
          backendPort: containerConnectionPort
          enableFloatingIP: false
          idleTimeoutInMinutes: 15
          protocol: 'Tcp'
          enableTcpReset: true
          loadDistribution: 'Default'
          disableOutboundSnat: false
          backendAddressPools: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, backendAddressPoolName)
            }
          ]
          probe: readinessProbeContainerName != '' ? {
            id: resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, '${readinessProbeContainerName}-readinessProbe')
          } : null
        }
      }
    ]
    inboundNatRules: []
    outboundRules: []
    inboundNatPools: []
  }
}

// ContainerGroupProfile resource - Dev/Limited: supports ONLY a single container named 'demo'
// Apply platformOptions only when allowPlatformOptions=true.
// ACI does not support context.resource.properties.extensions.daprSidecar;
// this recipe does not project Dapr sidecar settings into the deployed container group profile.
resource containerGroupProfile 'Microsoft.ContainerInstance/containerGroupProfiles@2024-11-01-preview' = {
  name: cgProfileName
  location: effectiveLocation
  properties: union(
    {
      sku: isConfidential ? 'Confidential' : 'Standard'
      // Init containers (initContainer: true) are placed in the separate initContainers[] array below.
      // Regular containers only — init containers are excluded from this array.
      containers: reduce(regularContainerItems, [], (acc, item) => concat(acc, [{
        name: item.key
        properties: union(
          {
            image: item.value.image
            ports: contains(item.value, 'ports') ? reduce(items(item.value.ports), [], (portAcc, port) => concat(portAcc, [{
              protocol: port.value.?protocol ?? 'TCP'
              port: port.value.containerPort
            }])) : []
            resources: {
              requests: {
                // ACI memoryInGB must be positive; Bicep only does integer division,
                // so enforce a minimum of 1 GiB for containers requesting < 1024 MiB.
                memoryInGB: max(1, int(item.value.?resources.?requests.?memoryInMib ?? 1024) / 1024)
                cpu: item.value.?resources.?requests.?cpu ?? json('1.0')
              }
            }
          },
          // Add environment variables from container definition, connections, and secrets UAI
          (contains(item.value, 'env') || length(connectionEnvVars) > 0 || length(secretsEnvVars) > 0) ? {
            environmentVariables: concat(
              // Container-defined env vars (handles both plain values and secretKeyRef)
              reduce(items(item.value.?env ?? {}), [], (envAcc, envItem) => concat(envAcc, [{
                name: envItem.key
                value: envItem.value.?value != null
                  ? string(envItem.value.value)
                  : envItem.value.?valueFrom.?secretKeyRef != null
                    ? string(envItem.value.valueFrom.secretKeyRef.key)
                    : string(envItem.value)
              }])),
              // Connection-derived env vars
              connectionEnvVars,
              // Azure SDK env vars for secrets UAI (AZURE_CLIENT_ID, AZURE_KEYVAULT_URI)
              secretsEnvVars
            )
          } : {},
          // Add volume mounts if they exist (filter out mounts for unsupported volume types like secretName)
          contains(item.value, 'volumeMounts') ? {
            volumeMounts: reduce(filter(item.value.volumeMounts, vm => contains(aciVolumeNames, vm.volumeName)), [], (vmAcc, vm) => concat(vmAcc, [
              union(
                {
                  name: vm.volumeName
                  mountPath: vm.mountPath
                },
                (vm.?readOnly ?? false) == true ? { readOnly: true } : {}
              )
            ]))
          } : {},
          // Note: ACI does not support Radius container properties `args` or `workingDir`.
          // If `args` is provided, merge command + args into a single ACI `command` array.
          // `workingDir` is ignored for this recipe.
          contains(item.value, 'command') ? {
            command: contains(item.value, 'args')
              ? concat(item.value.command, item.value.args)
              : item.value.command
          } : {}
        )
      }]))
      // Init containers run sequentially to completion before regular containers start.
      // The ACI init container schema is a subset: supports command, environmentVariables,
      // image, securityContext, and volumeMounts — but NOT ports, resources, livenessProbe,
      // readinessProbe, or configMap.
      initContainers: reduce(initContainerItems, [], (acc, item) => concat(acc, [{
        name: item.key
        properties: union(
          {
            image: item.value.image
          },
          // Env vars from container definition only (no connection env vars for init containers)
          contains(item.value, 'env') ? {
            environmentVariables: reduce(items(item.value.?env ?? {}), [], (envAcc, envItem) => concat(envAcc, [{
              name: envItem.key
              value: envItem.value.?value != null
                ? string(envItem.value.value)
                : envItem.value.?valueFrom.?secretKeyRef != null
                  ? string(envItem.value.valueFrom.secretKeyRef.key)
                  : string(envItem.value)
            }]))
          } : {},
          // Volume mounts (filter out unsupported secretName volumes)
          contains(item.value, 'volumeMounts') ? {
            volumeMounts: reduce(filter(item.value.volumeMounts, vm => contains(aciVolumeNames, vm.volumeName)), [], (vmAcc, vm) => concat(vmAcc, [
              union(
                {
                  name: vm.volumeName
                  mountPath: vm.mountPath
                },
                (vm.?readOnly ?? false) == true ? { readOnly: true } : {}
              )
            ]))
          } : {},
          // Merge command + args into a single command array (args and workingDir not supported by ACI init containers)
          contains(item.value, 'command') ? {
            command: contains(item.value, 'args')
              ? concat(item.value.command, item.value.args)
              : item.value.command
          } : {}
        )
      }]))
      volumes: !empty(aciVolumes)
        ? aciVolumes
        : [
            {
              name: 'cachevolume'
              emptyDir: {}
            }
          ]
      restartPolicy: resourceProperties.?restartPolicy ?? 'Always'
      ipAddress: {
        ports: [
          {
            protocol: 'TCP'
            port: containerConnectionPort
          }
        ]
        type: 'Private'
      }
      osType: 'Linux'
    },
    isConfidential ? {
      confidentialComputeProperties: {
        ccePolicy: ccePolicy
        isolationType: 'SevSnp'
      }
    } : {}
  )
}

// NGroups
resource nGroups 'Microsoft.ContainerInstance/NGroups@2024-11-01-preview' = {
  name: nGroupsName
  location: effectiveLocation
  zones: zones
  // Run under the UAI created by the secrets recipe so containers can
  // access Key Vault via ManagedIdentityCredential. Only set when a
  // secrets connection provides a UAI.
  identity: secretsUaiId != '' ? {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${secretsUaiId}': {}
    }
  } : null
  properties: {
    elasticProfile: {
      // ACI scaling comes from recipe parameters, not from Radius replicas/autoScaling properties.
      desiredCount: desiredCount
      maintainDesiredCount: maintainDesiredCount
    }
    containerGroupProfiles: [
      {
        resource: {
          id: resourceId('Microsoft.ContainerInstance/containerGroupProfiles', cgProfileName)
        }
        containerGroupProperties: {
          subnetIds: [
            {
              id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)
              name: subnetName
            }
          ]
        }
        networkProfile: {
          loadBalancer: {
            backendAddressPools: [
              {
                resource: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, backendAddressPoolName)
              }
            ]
          }
        }
      }
    ]
  }
  tags: {
    'reprovision.enabled': 'true'
    'metadata.container.environmentVariable.orchestratorId': 'true'
    'rollingupdate.replace.enabled': 'true'
  }
  dependsOn: [
    containerGroupProfile
    loadBalancer
    virtualNetwork
  ]
}

// Outputs
output result object = {
  virtualNetworkId: virtualNetwork.id
  subnetId: virtualNetwork.properties.subnets[0].id
  loadBalancerId: loadBalancer.id
  frontendIPConfigurationId: loadBalancer.properties.frontendIPConfigurations[0].id
  backendAddressPoolId: loadBalancer.properties.backendAddressPools[0].id
  inboundPublicIPId: inboundPublicIP.id
  outboundPublicIPId: outboundPublicIP.id
  inboundPublicIPFQDN: inboundPublicIP.properties.dnsSettings.fqdn
  natGatewayId: natGateway.id
  networkSecurityGroupId: networkSecurityGroup.id
  ddosProtectionPlanId: enableDdosProtection ? ddosProtectionPlan.id : ''
  containerGroupProfileId: containerGroupProfile.id
  nGroupsId: nGroups.id
  readinessProbeId: readinessProbeContainerName != '' ? resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, '${readinessProbeContainerName}-readinessProbe') : ''
  livenessProbeId: length(filter(regularContainerItems, item => contains(item.value, 'livenessProbe') && item.value.livenessProbe != null)) > 0 ? resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, '${filter(regularContainerItems, item => contains(item.value, 'livenessProbe') && item.value.livenessProbe != null)[0].key}-livenessProbe') : ''
}
