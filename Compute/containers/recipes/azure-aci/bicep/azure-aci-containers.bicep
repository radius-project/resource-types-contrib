@description('Container Instance API version')
@maxLength(32)
param apiVersion string = '2024-09-01-preview'

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
param desiredCount int = 3

@description('Availability zones')
param zones array = []

@description('Maintain desired count')
param maintainDesiredCount bool = true

@description('Inbound NAT Rule name')
@maxLength(64)
param inboundNatRuleName string = 'inboundNatRule'

@description('Enable DDoS protection (limit: 1 plan per subscription per region)')
param enableDdosProtection bool = false

@description('Name of an existing DDoS protection plan (required when enableDdosProtection is true)')
param ddosProtectionPlanName string = 'ddosProtectionPlan'

@description('Radius ACI Container Context')
param context object

// Variables
var cgProfileName = containerGroupProfileName
var nGroupsName = nGroupsParamName
var resourcePrefix = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/'
var loadBalancerApiVersion = '2022-07-01'
var vnetApiVersion = '2022-07-01'
var publicIPVersion = '2022-07-01'
var resourceProperties = context.resource.properties ?? {}
var resourceVolumes = resourceProperties.?volumes ?? {}
var resolvedConnections = context.resource.?connections ?? {}

// Extract container items from context
var containerItems = items(context.resource.properties.?containers ?? {})

// Find the first container with a readiness probe for load balancer probe reference
var firstContainerWithReadinessProbe = length(filter(containerItems, item => contains(item.value, 'readinessProbe') && item.value.readinessProbe != null)) > 0 
  ? filter(containerItems, item => contains(item.value, 'readinessProbe') && item.value.readinessProbe != null)[0]
  : null

// Extract connection data from linked resources (merged with resource properties)
var resourceConnections = context.resource.?connections ?? {}
var connectionDefinitions = context.resource.properties.?connections ?? {}

// Properties to exclude from connection environment variables
var excludedProperties = ['recipe', 'status', 'provisioningState']

// Helper function to check if a connection is a secrets resource (using source from original connection definition)
var isSecretsResource = reduce(items(connectionDefinitions), {}, (acc, conn) => union(acc, {
  '${conn.key}': contains(string(conn.value.?source ?? ''), 'Radius.Security/secrets')
}))

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
// Note: 'secretName' volumes (K8s-style secret mounts) are skipped for ACI —
// secrets are accessed via env vars (AZURE_CLIENT_ID, AZURE_KEYVAULT_URI) instead.
var volumeItems = filter(items(resourceVolumes), vol => contains(vol.value, 'persistentVolume') || contains(vol.value, 'emptyDir'))
var aciVolumeNames = map(volumeItems, vol => vol.key)
var aciVolumes = reduce(volumeItems, [], (acc, vol) => concat(acc, [
  union(
    { name: vol.key },
    contains(vol.value, 'persistentVolume') && contains(resolvedConnections, vol.key) ? {
      azureFile: {
        shareName: string(resolvedConnections[vol.key].?status.?computedValues.?shareName ?? '')
        storageAccountName: string(resolvedConnections[vol.key].?status.?computedValues.?storageAccountName ?? '')
        storageAccountKey: string(resolvedConnections[vol.key].?status.?secrets.?storageAccountKey.?Value ?? '')
        readOnly: string(vol.value.persistentVolume.?accessMode ?? '') == 'ReadOnlyMany'
      }
    } : {},
    contains(vol.value, 'emptyDir') ? { emptyDir: {} } : {}
  )
]))

// Build volume mounts from demo container definition
// volumeMounts is an array: [{name, containerPath, readOnly}]
var rawVolumeMounts = resourceProperties.?containers.?demo.?volumeMounts ?? []
var aciVolumeMounts = reduce(rawVolumeMounts, [], (acc, vm) => concat(acc, [
  union(
    {
      name: vm.volumeName      
      mountPath: vm.mountPath
    },
    (vm.?readOnly ?? false) == true ? { readOnly: true } : {}
  )
]))

// DDoS Protection Plan — use existing if already present (limit: 1 per subscription per region)
resource ddosProtectionPlan 'Microsoft.Network/ddosProtectionPlans@2022-07-01' existing = if (enableDdosProtection) {
  name: ddosProtectionPlanName
}

// Network Security Group
resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2022-07-01' = {
  name: networkSecurityGroupName
  location: resourceGroup().location
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
  location: resourceGroup().location
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
  location: resourceGroup().location
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
  location: resourceGroup().location
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
  location: resourceGroup().location
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
  location: resourceGroup().location
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
          properties: {
            protocol: 'Tcp'
            port: item.value.readinessProbe.?tcpSocket.?port ?? 80
            intervalInSeconds: item.value.readinessProbe.?periodSeconds ?? 5
            numberOfProbes: item.value.readinessProbe.?failureThreshold ?? 3
            probeThreshold: item.value.readinessProbe.?successThreshold ?? 1
          }
        }] : [],
        // Add liveness probe if exists for this container
        contains(item.value, 'livenessProbe') && item.value.livenessProbe != null ? [{
          name: '${item.key}-livenessProbe'
          properties: {
            protocol: 'Tcp'
            port: item.value.livenessProbe.?tcpSocket.?port ?? 80
            intervalInSeconds: item.value.livenessProbe.?periodSeconds ?? 10
            numberOfProbes: item.value.livenessProbe.?failureThreshold ?? 3
            probeThreshold: item.value.livenessProbe.?successThreshold ?? 1
          }
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
          frontendPort: 80
          backendPort: 80
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
    inboundNatRules: [
      {
        name: inboundNatRuleName
        properties: {
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, backendAddressPoolName)
          }
          backendPort: 80
          enableFloatingIP: false
          enableTcpReset: false
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, frontendIPName)
          }
          frontendPortRangeEnd: 331
          frontendPortRangeStart: 81
          idleTimeoutInMinutes: 4
          protocol: 'Tcp'
        }
      }
    ]
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
resource containerGroupProfile 'Microsoft.ContainerInstance/containerGroupProfiles@2024-09-01-preview' = {
  name: cgProfileName
  location: resourceGroup().location
  properties: union(
    {
      sku: toLower(string(context.resource.properties.?platformOptions.?sku ?? 'Standard')) == 'confidential' ? 'Confidential' : 'Standard'
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
          // Add command if specified (ACI does not support 'args' or 'workingDir' separately;
          // merge command + args into a single 'command' array for ACI)
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
            port: 80
          }
        ]
        type: 'Private'
      }
      osType: 'Linux'
    },
    toLower(string(resourceProperties.?platformOptions.?sku ?? 'standard')) == 'confidential' ? {
      confidentialComputeProperties: {
        ccePolicy: 'cGFja2FnZSBwb2xpY3kKCmltcG9ydCBmdXR1cmUua2V5d29yZHMuZXZlcnkKaW1wb3J0IGZ1dHVyZS5rZXl3b3Jkcy5pbgoKYXBpX3ZlcnNpb24gOj0gIjAuMTAuMCIKZnJhbWV3b3JrX3ZlcnNpb24gOj0gIjAuMi4zIgoKZnJhZ21lbnRzIDo9IFsKICB7CiAgICAiZmVlZCI6ICJtY3IubWljcm9zb2Z0LmNvbS9hY2kvYWNpLWNjLWluZnJhLWZyYWdtZW50IiwKICAgICJpbmNsdWRlcyI6IFsKICAgICAgImNvbnRhaW5lcnMiLAogICAgICAiZnJhZ21lbnRzIgogICAgXSwKICAgICJpc3N1ZXIiOiAiZGlkOng1MDk6MDpzaGEyNTY6SV9faXVMMjVvWEVWRmRUUF9hQkx4X2VUMVJQSGJDUV9FQ0JRZllacHQ5czo6ZWt1OjEuMy42LjEuNC4xLjMxMS43Ni41OS4xLjMiLAogICAgIm1pbmltdW1fc3ZuIjogIjQiCiAgfQpdCgpjb250YWluZXJzIDo9IFt7ImFsbG93X2VsZXZhdGVkIjpmYWxzZSwiYWxsb3dfc3RkaW9fYWNjZXNzIjp0cnVlLCJjYXBhYmlsaXRpZXMiOnsiYW1iaWVudCI6W10sImJvdW5kaW5nIjpbIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRlNFVElEIiwiQ0FQX0ZPV05FUiIsIkNBUF9NS05PRCIsIkNBUF9ORVRfUkFXIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRVSUQiLCJDQVBfU0VURkNBUCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfU1lTX0NIUk9PVCIsIkNBUF9LSUxMIiwiQ0FQX0FVRElUX1dSSVRFIl0sImVmZmVjdGl2ZSI6WyJDQVBfQ0hPV04iLCJDQVBfREFDX09WRVJSSURFIiwiQ0FQX0ZTRVRJRCIsIkNBUF9GT1dORVIiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRHSUQiLCJDQVBfU0VUVUlEIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUUENBUCIsIkNBUF9ORVRfQklORF9TRVJWSUNFIiwiQ0FQX1NZU19DSFJPT1QiLCJDQVBfS0lMTCIsIkNBUF9BVURJVF9XUklURSJdLCJpbmhlcml0YWJsZSI6W10sInBlcm1pdHRlZCI6WyJDQVBfQ0hPV04iLCJDQVBfREFDX09WRVJSSURFIiwiQ0FQX0ZTRVRJRCIsIkNBUF9GT1dORVIiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRHSUQiLCJDQVBfU0VUVUlEIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUUENBUCIsIkNBUF9ORVRfQklORF9TRVJWSUNFIiwiQ0FQX1NZU19DSFJPT1QiLCJDQVBfS0lMTCIsIkNBUF9BVURJVF9XUklURSJdfSwiY29tbWFuZCI6WyIvcGF1c2UiXSwiZW52X3J1bGVzIjpbeyJwYXR0ZXJuIjoiUEFUSD0vdXNyL2xvY2FsL3NiaW46L3Vzci9sb2NhbC9iaW46L3Vzci9zYmluOi91c3IvYmluOi9zYmluOi9iaW4iLCJyZXF1aXJlZCI6dHJ1ZSwic3RyYXRlZ3kiOiJzdHJpbmcifSx7InBhdHRlcm4iOiJURVJNPXh0ZXJtIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9XSwiZXhlY19wcm9jZXNzZXMiOltdLCJsYXllcnMiOlsiMTZiNTE0MDU3YTA2YWQ2NjVmOTJjMDI4NjNhY2EwNzRmZDU5NzZjNzU1ZDI2YmZmMTYzNjUyOTkxNjllODQxNSJdLCJtb3VudHMiOltdLCJuYW1lIjoicGF1c2UtY29udGFpbmVyIiwibm9fbmV3X3ByaXZpbGVnZXMiOmZhbHNlLCJzZWNjb21wX3Byb2ZpbGVfc2hhMjU2IjoiIiwic2lnbmFscyI6W10sInVzZXIiOnsiZ3JvdXBfaWRuYW1lcyI6W3sicGF0dGVybiI6IiIsInN0cmF0ZWd5IjoiYW55In1dLCJ1bWFzayI6IjAwMjIiLCJ1c2VyX2lkbmFtZSI6eyJwYXR0ZXJuIjoiIiwic3RyYXRlZ3kiOiJhbnkifX0sIndvcmtpbmdfZGlyIjoiLyJ9LHsiYWxsb3dfZWxldmF0ZWQiOmZhbHNlLCJhbGxvd19zdGRpb19hY2Nlc3MiOnRydWUsImNhcGFiaWxpdGllcyI6eyJhbWJpZW50IjpbXSwiYm91bmRpbmciOlsiQ0FQX0FVRElUX1dSSVRFIiwiQ0FQX0NIT1dOIiwiQ0FQX0RBQ19PVkVSUklERSIsIkNBUF9GT1dORVIiLCJDQVBfRlNFVElEIiwiQ0FQX0tJTEwiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX0JJTkRfU0VSVklDRSIsIkNBUF9ORVRfUkFXIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUR0lEIiwiQ0FQX1NFVFBDQVAiLCJDQVBfU0VUVUlEIiwiQ0FQX1NZU19DSFJPT1QiXSwiZWZmZWN0aXZlIjpbIkNBUF9BVURJVF9XUklURSIsIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRk9XTkVSIiwiQ0FQX0ZTRVRJRCIsIkNBUF9LSUxMIiwiQ0FQX01LTk9EIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRGQ0FQIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX1NFVFVJRCIsIkNBUF9TWVNfQ0hST09UIl0sImluaGVyaXRhYmxlIjpbXSwicGVybWl0dGVkIjpbIkNBUF9BVURJVF9XUklURSIsIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRk9XTkVSIiwiQ0FQX0ZTRVRJRCIsIkNBUF9LSUxMIiwiQ0FQX01LTk9EIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRGQ0FQIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX1NFVFVJRCIsIkNBUF9TWVNfQ0hST09UIl19LCJjb21tYW5kIjpbIi9iaW4vc2giLCItYyIsIm5naW54IC1nIFwiZGFlbW9uIG9mZjtcIiJdLCJlbnZfcnVsZXMiOlt7InBhdHRlcm4iOiJBQ01FX1ZFUlNJT049MC4zLjEiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5Ijoic3RyaW5nIn0seyJwYXR0ZXJuIjoiQ09OTkVDVElPTlNfREFUQV8uKz0uKyIsInJlcXVpcmVkIjp0cnVlLCJzdHJhdGVneSI6InJlMiJ9LHsicGF0dGVybiI6IkNPTk5FQ1RJT05TX1NFQ1JFVFNfLis9LisiLCJyZXF1aXJlZCI6dHJ1ZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJDT05ORUNUSU9OU19TRUNSRVRfQVBJS0VZPS4rIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InJlMiJ9LHsicGF0dGVybiI6IkNPTk5FQ1RJT05TX1NFQ1JFVF9QQVNTV09SRD0uKyIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJyZTIifSx7InBhdHRlcm4iOiJDT05ORUNUSU9OU19TRUNSRVRfVVNFUk5BTUU9LisiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5IjoicmUyIn0seyJwYXR0ZXJuIjoiRFlOUEtHX1JFTEVBU0U9MSIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJzdHJpbmcifSx7InBhdHRlcm4iOiJOR0lOWF9WRVJTSU9OPTEuMjkuOCIsInJlcXVpcmVkIjpmYWxzZSwic3RyYXRlZ3kiOiJzdHJpbmcifSx7InBhdHRlcm4iOiJOSlNfUkVMRUFTRT0xIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9LHsicGF0dGVybiI6Ik5KU19WRVJTSU9OPTAuOS42IiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9LHsicGF0dGVybiI6IlBBVEg9L3Vzci9sb2NhbC9zYmluOi91c3IvbG9jYWwvYmluOi91c3Ivc2JpbjovdXNyL2Jpbjovc2JpbjovYmluIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9LHsicGF0dGVybiI6IlBLR19SRUxFQVNFPTEiLCJyZXF1aXJlZCI6ZmFsc2UsInN0cmF0ZWd5Ijoic3RyaW5nIn1dLCJleGVjX3Byb2Nlc3NlcyI6W10sImlkIjoibmdpbng6YWxwaW5lIiwibGF5ZXJzIjpbIjBiNWQ2MDQ1ODU0NjA3MmMyYmJkZDEwZTRmNzk0NTI2OTgwNGFkOGI5ZjM4NjgxYTQ1M2M3MDk1YmM1ZTFmMTYiLCI1YTc2NWUwOTg5MDI1ODg3MDE0YzgwNjhlYjNhMjIzOWI2ZDJiMDMzNDZlMjQwZjVkNDg4OGI0YjM5NmViZjY4IiwiY2YwY2RlZDhjNDI1Nzc2MmIwM2MzNmI5YjJlYzdjNmU2NTdjNmQxZmMzZWRmM2EzMzEyNWMwYzA0YjRkNWU2YyIsIjM1MjE0ZjBmZWI5OTRiODY3MmRmYjg3MjcyMzY5OTg3YzYzZWM4N2ZjODExYWIzNDcwYWFkMTdlODViZTk5OWEiLCJkZmQ4OTRhZjg5NWMyY2YzZmRlODYzMzlhMWU5ZTg4ZTY2ZWI4ZWIwOTdkNjQyNzk5ODA2NzM2N2EyZDA4NWY3IiwiNDhlODhmOWZiYzQ4YjFlZTJjY2MwMjBmMTFjNmZlNTE2NTgyNjY1NzA4MGM4M2E0NzE0Y2UzZThkMmIxNDczZCIsIjA3Mjc2YjkzYmU1OWJhM2VmZmRiZjFhNjVkOTYyZDRlN2Q0YWFmM2E2NTE3NmZlMTJjNjZhYTc1NGI5YWVlNjIiLCI3NTc4ZGQ5ODEyNjk4OTM5YjUyNmVkODZhYWFmZjFjZjM3YWNiY2JiZDc1MjQ3ZjYwZjM4NDViOWE5MWZkMGM1Il0sIm1vdW50cyI6W3siZGVzdGluYXRpb24iOiIvYXBwL2RhdGEiLCJvcHRpb25zIjpbInJiaW5kIiwicnNoYXJlZCJdLCJzb3VyY2UiOiJbcmVzb3VyY2VJZCgnUmFkaXVzLkNvbXB1dGUvcGVyc2lzdGVudFZvbHVtZXMnLCAnbXlwZXJzaXN0ZW50dm9sdW1lJyldIiwidHlwZSI6ImJpbmQifSx7ImRlc3RpbmF0aW9uIjoiL2V0Yy9yZXNvbHYuY29uZiIsIm9wdGlvbnMiOlsicmJpbmQiLCJyc2hhcmVkIiwicnciXSwic291cmNlIjoic2FuZGJveDovLy90bXAvYXRsYXMvcmVzb2x2Y29uZi8uKyIsInR5cGUiOiJiaW5kIn0seyJkZXN0aW5hdGlvbiI6Ii9ldGMvc2VjcmV0cyIsIm9wdGlvbnMiOlsicmJpbmQiLCJybyIsInJzaGFyZWQiXSwic291cmNlIjoiW2Zvcm1hdCgnYXBwLXNlY3JldHMtezB9JywgdW5pcXVlU3RyaW5nKGRlcGxveW1lbnQoKS5uYW1lKSldIiwidHlwZSI6ImJpbmQifSx7ImRlc3RpbmF0aW9uIjoiL3RtcC9jYWNoZSIsIm9wdGlvbnMiOlsicmJpbmQiLCJyc2hhcmVkIl0sInNvdXJjZSI6ImVwaGVtZXJhbDovL2NhY2hlIiwidHlwZSI6ImJpbmQifV0sIm5hbWUiOiJuZ2lueDphbHBpbmUiLCJub19uZXdfcHJpdmlsZWdlcyI6ZmFsc2UsInNlY2NvbXBfcHJvZmlsZV9zaGEyNTYiOiIiLCJzaWduYWxzIjpbM10sInVzZXIiOnsiZ3JvdXBfaWRuYW1lcyI6W3sicGF0dGVybiI6IiIsInN0cmF0ZWd5IjoiYW55In1dLCJ1bWFzayI6IjAwMjIiLCJ1c2VyX2lkbmFtZSI6eyJwYXR0ZXJuIjoiIiwic3RyYXRlZ3kiOiJhbnkifX0sIndvcmtpbmdfZGlyIjoiL3Vzci9zaGFyZS9uZ2lueC9odG1sIn1dCgphbGxvd19wcm9wZXJ0aWVzX2FjY2VzcyA6PSB0cnVlCmFsbG93X2R1bXBfc3RhY2tzIDo9IGZhbHNlCmFsbG93X3J1bnRpbWVfbG9nZ2luZyA6PSBmYWxzZQphbGxvd19lbnZpcm9ubWVudF92YXJpYWJsZV9kcm9wcGluZyA6PSB0cnVlCmFsbG93X3VuZW5jcnlwdGVkX3NjcmF0Y2ggOj0gZmFsc2UKYWxsb3dfY2FwYWJpbGl0eV9kcm9wcGluZyA6PSB0cnVlCgptb3VudF9kZXZpY2UgOj0gZGF0YS5mcmFtZXdvcmsubW91bnRfZGV2aWNlCnVubW91bnRfZGV2aWNlIDo9IGRhdGEuZnJhbWV3b3JrLnVubW91bnRfZGV2aWNlCm1vdW50X292ZXJsYXkgOj0gZGF0YS5mcmFtZXdvcmsubW91bnRfb3ZlcmxheQp1bm1vdW50X292ZXJsYXkgOj0gZGF0YS5mcmFtZXdvcmsudW5tb3VudF9vdmVybGF5CmNyZWF0ZV9jb250YWluZXIgOj0gZGF0YS5mcmFtZXdvcmsuY3JlYXRlX2NvbnRhaW5lcgpleGVjX2luX2NvbnRhaW5lciA6PSBkYXRhLmZyYW1ld29yay5leGVjX2luX2NvbnRhaW5lcgpleGVjX2V4dGVybmFsIDo9IGRhdGEuZnJhbWV3b3JrLmV4ZWNfZXh0ZXJuYWwKc2h1dGRvd25fY29udGFpbmVyIDo9IGRhdGEuZnJhbWV3b3JrLnNodXRkb3duX2NvbnRhaW5lcgpzaWduYWxfY29udGFpbmVyX3Byb2Nlc3MgOj0gZGF0YS5mcmFtZXdvcmsuc2lnbmFsX2NvbnRhaW5lcl9wcm9jZXNzCnBsYW45X21vdW50IDo9IGRhdGEuZnJhbWV3b3JrLnBsYW45X21vdW50CnBsYW45X3VubW91bnQgOj0gZGF0YS5mcmFtZXdvcmsucGxhbjlfdW5tb3VudApnZXRfcHJvcGVydGllcyA6PSBkYXRhLmZyYW1ld29yay5nZXRfcHJvcGVydGllcwpkdW1wX3N0YWNrcyA6PSBkYXRhLmZyYW1ld29yay5kdW1wX3N0YWNrcwpydW50aW1lX2xvZ2dpbmcgOj0gZGF0YS5mcmFtZXdvcmsucnVudGltZV9sb2dnaW5nCmxvYWRfZnJhZ21lbnQgOj0gZGF0YS5mcmFtZXdvcmsubG9hZF9mcmFnbWVudApzY3JhdGNoX21vdW50IDo9IGRhdGEuZnJhbWV3b3JrLnNjcmF0Y2hfbW91bnQKc2NyYXRjaF91bm1vdW50IDo9IGRhdGEuZnJhbWV3b3JrLnNjcmF0Y2hfdW5tb3VudAoKcmVhc29uIDo9IHsiZXJyb3JzIjogZGF0YS5mcmFtZXdvcmsuZXJyb3JzfQ=='
      }
    } : {}
  )
}

// NGroups
resource nGroups 'Microsoft.ContainerInstance/NGroups@2024-09-01-preview' = {
  name: nGroupsName
  location: resourceGroup().location
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
