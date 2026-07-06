@description('NGroups parameter name')
@maxLength(64)
param nGroupsParamName string = 'ngroups-${uniqueString(resourceGroup().id)}'

@description('Container Group Profile name')
@maxLength(64)
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

@description('Enable DDoS protection (limit: 1 plan per subscription per region)')
param enableDdosProtection bool = false

@description('Name of an existing DDoS protection plan (required when enableDdosProtection is true)')
param ddosProtectionPlanName string = 'ddosProtectionPlan'

@description('Deployment location for all resources. Reads from platformOptions.location if provided.')
param location string = context.resource.properties.?platformOptions.?location ?? resourceGroup().location

@description('Radius ACI Container Context')
param context object

// Variables
var cgProfileName = containerGroupProfileName
var nGroupsName = nGroupsParamName
var resourceProperties = context.resource.properties ?? {}
// ACI does not support Radius extensions.daprSidecar; this recipe intentionally
// ignores any Dapr sidecar configuration provided via context.resource.properties.extensions.
var resourceVolumes = resourceProperties.?volumes ?? {}
var resolvedConnections = context.resource.?connections ?? {}

// Extract container items from context
var containerItems = items(context.resource.properties.?containers ?? {})

// Derive the first container's first exposed port (used for ipAddress and LB rules)
var firstContainerPorts = length(containerItems) > 0 && contains(containerItems[0].value, 'ports') ? items(containerItems[0].value.ports) : []
var containerConnectionPort = length(firstContainerPorts) > 0 ? firstContainerPorts[0].value.containerPort : 80

// Find the first container with a readiness probe for load balancer probe reference
var firstContainerWithReadinessProbe = length(filter(containerItems, item => contains(item.value, 'readinessProbe') && item.value.readinessProbe != null)) > 0 
  ? filter(containerItems, item => contains(item.value, 'readinessProbe') && item.value.readinessProbe != null)[0]
  : null

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
  location: location
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
  location: location
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
  location: location
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
  location: location
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
  dependsOn: [
    outboundPublicIP
  ]
}

// Virtual Network
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2022-07-01' = {
  name: vnetName
  location: location
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
  dependsOn: [
    networkSecurityGroup
    natGateway
  ]
}

// Load Balancer
resource loadBalancer 'Microsoft.Network/loadBalancers@2022-07-01' = {
  name: loadBalancerName
  location: location
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
    probes: reduce(containerItems, [], (acc, item) => concat(acc, 
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
          probe: firstContainerWithReadinessProbe != null ? {
            id: resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, '${firstContainerWithReadinessProbe.key}-readinessProbe')
          } : null
        }
      }
    ]
    inboundNatRules: []
    outboundRules: []
    inboundNatPools: []
  }
  dependsOn: [
    inboundPublicIP
    virtualNetwork
  ]
}

// ContainerGroupProfile resource - Dev/Limited: supports ONLY a single container named 'demo'
// Create default CGProfile when platformOptions is not provided else use the CGProfile resource provided by the customer.
// ACI does not support context.resource.properties.extensions.daprSidecar;
// this recipe does not project Dapr sidecar settings into the deployed container group profile.
resource containerGroupProfile 'Microsoft.ContainerInstance/containerGroupProfiles@2024-11-01-preview' = {
  name: cgProfileName
  location: location
  properties: union(
    {
      sku: isConfidential ? 'Confidential' : 'Standard'
      containers: reduce(containerItems, [], (acc, item) => concat(acc, [{
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
          // Add environment variables from container definition and connections
          (contains(item.value, 'env') || length(connectionEnvVars) > 0) ? {
            environmentVariables: concat(
              // Container-defined env vars
              reduce(items(item.value.?env ?? {}), [], (envAcc, envItem) => concat(envAcc, [{
                name: envItem.key
                value: envItem.value.?value ?? string(envItem.value)
              }])),
              // Connection-derived env vars
              connectionEnvVars
            )
          } : {},
          // Add volume mounts if they exist (filter out mounts for unsupported volume types like secretName)
          contains(item.value, 'volumeMounts') ? {
            volumeMounts: reduce(item.value.volumeMounts, [], (vmAcc, vm) => concat(vmAcc, [{
              name: vm.volumeName
              mountPath: vm.mountPath
            }]))
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
      volumes: [
        {
          name: 'cachevolume'
          emptyDir: {}   // ephemeral volume
        }
      ]
      restartPolicy: 'Always'
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
  location: location
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
                resource: {
                  id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, backendAddressPoolName)
                }
              }
            ]
          }
        }
      }
    ]
  }
  tags: {
    'reprovision.enabled': true
    'metadata.container.environmentVariable.orchestratorId': true
    'rollingupdate.replace.enabled': true
  }
  dependsOn: [
    containerGroupProfile
    loadBalancer
    virtualNetwork
  ]
}

// Outputs
output virtualNetworkId string = virtualNetwork.id
output subnetId string = virtualNetwork.properties.subnets[0].id
output loadBalancerId string = loadBalancer.id
output frontendIPConfigurationId string = loadBalancer.properties.frontendIPConfigurations[0].id
output backendAddressPoolId string = loadBalancer.properties.backendAddressPools[0].id
output inboundPublicIPId string = inboundPublicIP.id
output outboundPublicIPId string = outboundPublicIP.id
output inboundPublicIPFQDN string = inboundPublicIP.properties.dnsSettings.fqdn
output natGatewayId string = natGateway.id
output networkSecurityGroupId string = networkSecurityGroup.id
output ddosProtectionPlanId string = enableDdosProtection ? ddosProtectionPlan.id : ''
output containerGroupProfileId string = containerGroupProfile.id
output nGroupsId string = nGroups.id
output readinessProbeId string = firstContainerWithReadinessProbe != null ? resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, '${firstContainerWithReadinessProbe.key}-readinessProbe') : ''
output livenessProbeId string = length(filter(containerItems, item => contains(item.value, 'livenessProbe') && item.value.livenessProbe != null)) > 0 ? resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, '${filter(containerItems, item => contains(item.value, 'livenessProbe') && item.value.livenessProbe != null)[0].key}-livenessProbe') : ''
