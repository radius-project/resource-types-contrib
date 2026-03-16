@description('Container Instance API version')
@maxLength(32)
param apiVersion string = '2024-09-01-preview'

@description('NGroups parameter name')
@maxLength(64)
param nGroupsParamName string = 'nGroups_resource_1'

@description('Container Group Profile name')
@maxLength(64)
param containerGroupProfileName string = 'cgp_1'

@description('Load Balancer name')
@maxLength(64)
param loadBalancerName string = 'slb_1'

@description('Backend Address Pool name')
@maxLength(64)
param backendAddressPoolName string = 'bepool_1'

@description('Virtual Network name')
@maxLength(64)
param vnetName string = 'vnet_1'

@description('Subnet name')
@maxLength(64)
param subnetName string = 'subnet_1'

@description('Network Security Group name')
@maxLength(64)
param networkSecurityGroupName string = 'nsg_1'

@description('Inbound Public IP name')
@maxLength(64)
param inboundPublicIPName string = 'inboundPublicIP'

@description('Outbound Public IP name')
@maxLength(64)
param outboundPublicIPName string = 'outboundPublicIP'

@description('NAT Gateway name')
param natGatewayName string = 'natGateway1'

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

@description('Radius ACI Container Context')
param context object

// Variables
var cgProfileName = containerGroupProfileName
var nGroupsName = nGroupsParamName
var resourcePrefix = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/'
var loadBalancerApiVersion = '2022-07-01'
var vnetApiVersion = '2022-07-01'
var publicIPVersion = '2022-07-01'
var ddosProtectionPlanName = 'ddosProtectionPlan'

// Extract connection data from linked resources (merged with resource properties)
var resourceConnections = context.resource.?connections ?? {}
var connectionDefinitions = context.resource.properties.?connections ?? {}

// Properties to exclude from connection environment variables
var excludedProperties = ['recipe', 'status', 'provisioningState']

// Helper function to check if a connection is a secrets resource (using source from original connection definition)
var isSecretsResource = reduce(items(connectionDefinitions), {}, (acc, conn) => union(acc, {
  '${conn.key}': contains(string(conn.value.?source ?? ''), 'Radius.Security/secrets')
}))

// Secrets connections to inject via envFrom.secretRef
// The K8s secret name is the Radius resource name (last segment of the source ID)
var secretsEnvFrom = reduce(items(resourceConnections), [], (acc, conn) => 
  isSecretsResource[conn.key] && connectionDefinitions[conn.key].?disableDefaultEnvVars != true
    ? concat(acc, [{
        prefix: toUpper('CONNECTION_${conn.key}_')
        secretRef: {
          // Extract the secret name from the connection source (last segment of the resource ID)
          name: last(split(string(connectionDefinitions[conn.key].source), '/'))
        }
      }])
    : acc
)

// Build environment variables from non-secrets connections when not explicitly disabled via disableDefaultEnvVars
// Secrets connections use envFrom.secretRef instead for cleaner injection
// Each connection's resource properties become CONNECTION_<CONNECTION_NAME>_<PROPERTY_NAME>
var connectionEnvVars = reduce(items(resourceConnections), [], (acc, conn) => 
  // Only process non-secrets connections here (secrets use envFrom)
  !isSecretsResource[conn.key] && connectionDefinitions[conn.key].?disableDefaultEnvVars != true
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


// DDoS Protection Plan
resource ddosProtectionPlan 'Microsoft.Network/ddosProtectionPlans@2022-07-01' = {
  name: ddosProtectionPlanName
  location: resourceGroup().location
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
    enableDdosProtection: true
    ddosProtectionPlan: {
      id: ddosProtectionPlan.id
    }
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
    probes: union(
      context.resource.properties.?containers.?demo.?readinessProbe != null ? [
        {
          name: 'readinessProbe'
          properties: {
            protocol: 'Tcp'
            port: context.resource.properties.containers.demo.readinessProbe.?tcpSocket.?port ?? 80
            intervalInSeconds: context.resource.properties.containers.demo.readinessProbe.?periodSeconds ?? 5
            numberOfProbes: context.resource.properties.containers.demo.readinessProbe.?failureThreshold ?? 3
            probeThreshold: context.resource.properties.containers.demo.readinessProbe.?successThreshold ?? 1
          }
        }
      ] : [],
      context.resource.properties.?containers.?demo.?livenessProbe != null ? [
        {
          name: 'livenessProbe'
          properties: {
            protocol: 'Tcp'
            port: context.resource.properties.containers.demo.livenessProbe.?tcpSocket.?port ?? 80
            intervalInSeconds: context.resource.properties.containers.demo.livenessProbe.?periodSeconds ?? 10
            numberOfProbes: context.resource.properties.containers.demo.livenessProbe.?failureThreshold ?? 3
            probeThreshold: context.resource.properties.containers.demo.livenessProbe.?successThreshold ?? 1
          }
        }
      ] : []
    )
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
          probe: context.resource.properties.?containers.?demo.?readinessProbe != null ? {
            id: resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, 'readinessProbe')
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
          backendPort: '80'
          enableFloatingIP: 'false'
          enableTcpReset: 'false'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, frontendIPName)
          }
          frontendPortRangeEnd: '331'
          frontendPortRangeStart: '81'
          idleTimeoutInMinutes: '4'
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

// ContainerGroupProfile resource - Create default CGProfile when platformOptions is not provided else use the CGProfile resource provided by the customer.
resource containerGroupProfile 'Microsoft.ContainerInstance/containerGroupProfiles@2024-09-01-preview' = {
  name: cgProfileName
  location: resourceGroup().location
  properties: union(
    {
      sku: toLower(string(context.resource.properties.?platformOptions.?sku ?? 'standard')) == 'confidential' ? 'Confidential' : 'Standard'
      containers: [
        {
          name: 'web'
          properties: union(
            {
              image: context.resource.properties.?containers.?demo.?image ?? 'nginx:latest'
              ports: [
                {
                  protocol: context.resource.properties.?containers.?demo.?ports != null ? context.resource.properties.?containers.?demo.?ports.?additionalProperties.?properties.?protocol ?? 'TCP' : 'TCP'
                  port: context.resource.properties.?containers.?demo.?ports != null ? context.resource.properties.?containers.?demo.?ports.?additionalProperties.?properties.?containerPort ?? 80 : 80
                }
              ]
              resources: {
                requests: {
                  memoryInGB: (context.resource.properties.containers.demo.?resources.?requests.?memoryInMib ?? 1024) / 1024
                  cpu: context.resource.properties.?containers.?demo.?resources.?requests.?cpu ?? json('1.0')
                }
              }
            },
            // Add environment variables from container definition and connections
            (contains(context.resource.properties.?containers.?demo ?? {}, 'env') || length(connectionEnvVars) > 0) ? {
              environmentVariables: concat(
                // Container-defined env vars
                reduce(items(context.resource.properties.?containers.?demo.?env ?? {}), [], (envAcc, envItem) => concat(envAcc, [{
                  name: envItem.key
                  value: envItem.value.?value ?? string(envItem.value)
                }])),
                // Connection-derived env vars
                connectionEnvVars
              )
            } : {},
            {
              volumeMounts: [
                {
                  name: 'cachevolume'
                  mountPath: '/mnt/cache' // ephemeral volume path in container filesystem
                }
              ]
            }
          )
        }
      ]
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
    // Add confidentialComputeProperties when SKU is Confidential
    toLower(string(context.resource.properties.?platformOptions.?sku ?? 'standard')) == 'confidential' ? {
      confidentialComputeProperties: {
        ccePolicy: 'cGFja2FnZSBwb2xpY3kKCmltcG9ydCBmdXR1cmUua2V5d29yZHMuZXZlcnkKaW1wb3J0IGZ1dHVyZS5rZXl3b3Jkcy5pbgoKYXBpX3ZlcnNpb24gOj0gIjAuMTAuMCIKZnJhbWV3b3JrX3ZlcnNpb24gOj0gIjAuMi4zIgoKZnJhZ21lbnRzIDo9IFsKICB7CiAgICAiZmVlZCI6ICJtY3IubWljcm9zb2Z0LmNvbS9hY2kvYWNpLWNjLWluZnJhLWZyYWdtZW50IiwKICAgICJpbmNsdWRlcyI6IFsKICAgICAgImNvbnRhaW5lcnMiLAogICAgICAiZnJhZ21lbnRzIgogICAgXSwKICAgICJpc3N1ZXIiOiAiZGlkOng1MDk6MDpzaGEyNTY6SV9faXVMMjVvWEVWRmRUUF9hQkx4X2VUMVJQSGJCUV9FQ0JRZllacHQ5czo6ZWt1OjEuMy42LjEuNC4xLjMxMS43Ni41OS4xLjMiLAogICAgIm1pbmltdW1fc3ZuIjogIjQiCiAgfQpdCgpjb250YWluZXJzIDo9IFt7ImFsbG93X2VsZXZhdGVkIjpmYWxzZSwiYWxsb3dfc3RkaW9fYWNjZXNzIjp0cnVlLCJjYXBhYmlsaXRpZXMiOnsiYW1iaWVudCI6W10sImJvdW5kaW5nIjpbIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRlNFVElEIiwiQ0FQX0ZPV05FUiIsIkNBUF9NS05PRCIsIkNBUF9ORVRfUkFXIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRVSUQiLCJDQVBfU0VURkNBUCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfU1lTX0NIUk9PVCIsIkNBUF9LSUxMIiwiQ0FQX0FVRElUX1dSSVRFIl0sImVmZmVjdGl2ZSI6WyJDQVBfQ0hPV04iLCJDQVBfREFDX09WRVJSSURFIiwiQ0FQX0ZTRVRJRCIsIkNBUF9GT1dORVIiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRHSUQiLCJDQVBfU0VUVUlEIiwiQ0FQX1NGVEZDQVAiLCJDQVBfU0VUUENBUCIsIkNBUF9ORVRfQklORF9TRVJWSUNFIiwiQ0FQX1NZU19DSFJPT1QiLCJDQVBfS0lMTCIsIkNBUF9BVURJVF9XUklURSJdLCJpbmhlcml0YWJsZSI6W10sInBlcm1pdHRlZCI6WyJDQVBfQ0hPV04iLCJDQVBfREFDX09WRVJSSURFIiwiQ0FQX0ZTRVRJRCIsIkNBUF9GT1dORVIiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRHSUQiLCJDQVBfU0VUVUlEIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUUENBUCIsIkNBUF9ORVRfQklORF9TRVJWSUNFIiwiQ0FQX1NZU19DSFJPT1QiLCJDQVBfS0lMTCIsIkNBUF9BVURJVF9XUklURSJdfSwiY29tbWFuZCI6WyIvcGF1c2UiXSwiZW52X3J1bGVzIjpbeyJwYXR0ZXJuIjoiUEFUSD0vdXNyL2xvY2FsL3NiaW46L3Vzci9sb2NhbC9iaW46L3Vzci9zYmluOi91c3IvYmluOi9zYmluOi9iaW4iLCJyZXF1aXJlZCI6dHJ1ZSwic3RyYXRlZ3kiOiJzdHJpbmcifSx7InBhdHRlcm4iOiJURVJNPXh0ZXJtIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9XSwiZXhlY19wcm9jZXNzZXMiOltdLCJsYXllcnMiOlsiMTZiNTE0MDU3YTA2YWQ2NjVmOTJjMDI4NjNhY2EwNzRmZDU5NzZjNzU1ZDI2YmZmMTYzNjUyOTkxNjllODQxNSJdLCJtb3VudHMiOltdLCJuYW1lIjoicGF1c2UtY29udGFpbmVyIiwibm9fbmV3X3ByaXZpbGVnZXMiOmZhbHNlLCJzZWNjb21wX3Byb2ZpbGVfc2hhMjU2IjoiIiwic2lnbmFscyI6W10sInVzZXIiOnsiZ3JvdXBfaWRuYW1lcyI6W3sicGF0dGVybiI6IiIsInN0cmF0ZWd5IjoiYW55In1dLCJ1bWFzayI6IjAwMjIiLCJ1c2VyX2lkbmFtZSI6eyJwYXR0ZXJuIjoiIiwic3RyYXRlZ3kiOiJhbnkifX0sIndvcmtpbmdfZGlyIjoiLyJ9LHsiYWxsb3dfZWxldmF0ZWQiOmZhbHNlLCJhbGxvd19zdGRpb19hY2Nlc3MiOnRydWUsImNhcGFiaWxpdGllcyI6eyJhbWJpZW50IjpbXSwiYm91bmRpbmciOlsiQ0FQX0FVRElUX1dSSVRFIiwiQ0FQX0NIT1dOIiwiQ0FQX0RBQ19PVkVSUklERSIsIkNBUF9GT1dORVIiLCJDQVBfRlNFVElEIiwiQ0FQX0tJTEwiLCJDQVBfTUtOT0QiLCJDQVBfTkVUX0JJTkRfU0VSVklDRSIsIkNBUF9ORVRfUkFXIiwiQ0FQX1NFVEZDQVAiLCJDQVBfU0VUR0lEIiwiQ0FQX1NFVFBDQVAiLCJDQVBfU0VUVUlEIiwiQ0FQX1NZU19DSFJPT1QiXSwiZWZmZWN0aXZlIjpbIkNBUF9BVURJVF9XUklURSIsIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRk9XTkVSIiwiQ0FQX0ZTRVRJRCIsIkNBUF9LSUxMIiwiQ0FQX01LTk9EIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRGQ0FQIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX1NFVFVJRCIsIkNBUF9TWVNfQ0hST09UIl0sImluaGVyaXRhYmxlIjpbXSwicGVybWl0dGVkIjpbIkNBUF9BVURJVF9XUklURSIsIkNBUF9DSE9XTiIsIkNBUF9EQUNfT1ZFUlJJREUiLCJDQVBfRk9XTkVSIiwiQ0FQX0ZTRVRJRCIsIkNBUF9LSUxMIiwiQ0FQX01LTk9EIiwiQ0FQX05FVF9CSU5EX1NFUlZJQ0UiLCJDQVBfTkVUX1JBVyIsIkNBUF9TRVRGQ0FQIiwiQ0FQX1NFVEdJRCIsIkNBUF9TRVRQQ0FQIiwiQ0FQX1NFVFVJRCIsIkNBUF9TWVNfQ0hST09UIl19LCJjb21tYW5kIjpbIi9iaW4vc2giLCItYyIsIm5vZGUgL3Vzci9zcmMvYXBwL2luZGV4LmpzIl0sImVudl9ydWxlcyI6W3sicGF0dGVybiI6IlBBVEg9L3Vzci9sb2NhbC9zYmluOi91c3IvbG9jYWwvYmluOi91c3Ivc2JpbjovdXNyL2Jpbjovc2JpbjovYmluIiwicmVxdWlyZWQiOmZhbHNlLCJzdHJhdGVneSI6InN0cmluZyJ9XSwiZXhlY19wcm9jZXNzZXMiOltdLCJpZCI6Im1jci5taWNyb3NvZnQuY29tL2F6dXJlZG9jcy9hY2ktaGVsbG93b3JsZCIsImxheWVycyI6WyJjODcwNjIxZDkyYTA1ZmE1MjMxYjgwMzIxOGJjMzMzYjI3YTNmZTVkNGExOTRhNTBiOGE5M2M5MWU4YWUyNTI2IiwiNDA5NjZiODFmZTk3OGIxMzM3NjgxMzIxYTBlZGNiOTZlZjZmYzQ5ODFiMTFmNThmNDM1MmE4YTNjMDdhNzUwYiIsImUxMGJjZTVlMjI3NTE2N2EyOGJkNDA4ZjUxYWNmMTljMTNhOTIyZTllMjA1MjBkZDgwOTA5NDM2ZDMzMGM1MWQiLCJmNDUzNDRiOWRjMDgxYTRkNjE4OTg2ZjRhYTM0ZjIyMTBlZTFlMTIxNTdkNjk2NTM5OTRkZGY2NjQ5MmQ4NTUwIiwiOTRmNDRmMjc1YjllMzkyYjc5ODRjMzU2MWQyZDM2ZGJlZGM5Nzk2ZDg3YzY0OGEwZWM1NGM4NDM2YmNmZTIyNSIsIjZlYmJmNzE2MTFkYzIxMWRjNWYyMjEyNDEzMjEwY2E1NGExMGQ0NGU1NTcyMGRmNTBmYjZjOTFmNzM5NDM0MmEiLCI4YjQ4NDJmMDY5ODI4MTc1MzRhNzViY2Y3MTg2NTIxM2IwOWRmYTgzMTMyMjljMzg0ZTUyMDFkYWRiZDc1ZTI1IiwiODlhODVjNTQ1YTk3ZjMyMmI1MjhmNGJmOWExMTlhMjkxMDdhMThlM2U0NDQ1OTdkYjUzODQ1Yzg4NjQyYjgyZSJdLCJtb3VudHMiOlt7ImRlc3RpbmF0aW9uIjoiL2V0Yy9yZXNvbHYuY29uZiIsIm9wdGlvbnMiOlsicmJpbmQiLCJyc2hhcmVkIiwicnciXSwic291cmNlIjoic2FuZGJveDovLy90bXAvYXRsYXMvcmVzb2x2Y29uZi8uKyIsInR5cGUiOiJiaW5kIn1dLCJuYW1lIjoibWNyLm1pY3Jvc29mdC5jb20vYXp1cmVkb2NzL2FjaS1oZWxsb3dvcmxkIiwibm9fbmV3X3ByaXZpbGVnZXMiOmZhbHNlLCJzZWNjb21wX3Byb2ZpbGVfc2hhMjU2IjoiIiwic2lnbmFscyI6W10sInVzZXIiOnsiZ3JvdXBfaWRuYW1lcyI6W3sicGF0dGVybiI6IiIsInN0cmF0ZWd5IjoiYW55In1dLCJ1bWFzayI6IjAwMjIiLCJ1c2VyX2lkbmFtZSI6eyJwYXR0ZXJuIjoiIiwic3RyYXRlZ3kiOiJhbnkifX0sIndvcmtpbmdfZGlyIjoiL3Vzci9zcmMvYXBwIn1dCgphbGxvd19wcm9wZXJ0aWVzX2FjY2VzcyA6PSB0cnVlCmFsbG93X2R1bXBfc3RhY2tzIDo9IGZhbHNlCmFsbG93X3J1bnRpbWVfbG9nZ2luZyA6PSBmYWxzZQphbGxvd19lbnZpcm9ubWVudF92YXJpYWJsZV9kcm9wcGluZyA6PSB0cnVlCmFsbG93X3VuZW5jcnlwdGVkX3NjcmF0Y2ggOj0gZmFsc2UKYWxsb3dfY2FwYWJpbGl0eV9kcm9wcGluZyA6PSB0cnVlCgptb3VudF9kZXZpY2UgOj0gZGF0YS5mcmFtZXdvcmsubW91bnRfZGV2aWNlCnVubW91bnRfZGV2aWNlIDo9IGRhdGEuZnJhbWV3b3JrLnVubW91bnRfZGV2aWNlCm1vdW50X292ZXJsYXkgOj0gZGF0YS5mcmFtZXdvcmsubW91bnRfb3ZlcmxheQp1bm1vdW50X292ZXJsYXkgOj0gZGF0YS5mcmFtZXdvcmsudW5tb3VudF9vdmVybGF5CmNyZWF0ZV9jb250YWluZXIgOj0gZGF0YS5mcmFtZXdvcmsuY3JlYXRlX2NvbnRhaW5lcgpleGVjX2luX2NvbnRhaW5lciA6PSBkYXRhLmZyYW1ld29yay5leGVjX2luX2NvbnRhaW5lcgpleGVjX2V4dGVybmFsIDo9IGRhdGEuZnJhbWV3b3JrLmV4ZWNfZXh0ZXJuYWwKc2h1dGRvd25fY29udGFpbmVyIDo9IGRhdGEuZnJhbWV3b3JrLnNodXRkb3duX2NvbnRhaW5lcgpzaWduYWxfY29udGFpbmVyX3Byb2Nlc3MgOj0gZGF0YS5mcmFtZXdvcmsuc2lnbmFsX2NvbnRhaW5lcl9wcm9jZXNzCnBsYW45X21vdW50IDo9IGRhdGEuZnJhbWV3b3JrLnBsYW45X21vdW50CnBsYW45X3VubW91bnQgOj0gZGF0YS5mcmFtZXdvcmsucGxhbjlfdW5tb3VudApnZXRfcHJvcGVydGllcyA6PSBkYXRhLmZyYW1ld29yay5nZXRfcHJvcGVydGllcwpkdW1wX3N0YWNrcyA6PSBkYXRhLmZyYW1ld29yay5kdW1wX3N0YWNrcwpydW50aW1lX2xvZ2dpbmcgOj0gZGF0YS5mcmFtZXdvcmsucnVudGltZV9sb2dnaW5nCmxvYWRfZnJhZ21lbnQgOj0gZGF0YS5mcmFtZXdvcmsubG9hZF9mcmFnbWVudApzY3JhdGNoX21vdW50IDo9IGRhdGEuZnJhbWV3b3JrLnNjcmF0Y2hfbW91bnQKc2NyYXRjaF91bm1vdW50IDo9IGRhdGEuZnJhbWV3b3JrLnNjcmF0Y2hfdW5tb3VudAoKcmVhc29uIDo9IHsiZXJyb3JzIjogZGF0YS5mcmFtZXdvcmsuZXJyb3JzfQ=='
      }
    } : {}
  )
}

// NGroups
resource nGroups 'Microsoft.ContainerInstance/NGroups@2024-09-01-preview' = {
  name: nGroupsName
  location: resourceGroup().location
  zones: zones
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    elasticProfile: {
      desiredCount: desiredCount
      maintainDesiredCount: maintainDesiredCount
    }
    updateProfile: {
      updateMode: 'Rolling'
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
output ddosProtectionPlanId string = ddosProtectionPlan.id
output containerGroupProfileId string = containerGroupProfile.id
output nGroupsId string = nGroups.id
output readinessProbeId string = context.resource.properties.?containers.?demo.?readinessProbe != null ? resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, 'readinessProbe') : ''
output livenessProbeId string = context.resource.properties.?containers.?demo.?livenessProbe != null ? resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, 'livenessProbe') : ''
