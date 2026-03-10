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

@description('Azure region for resource deployment')
param location string = 'WestEurope'

// Variables
var cgProfileName = containerGroupProfileName
var nGroupsName = nGroupsParamName
var resourcePrefix = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/'
var loadBalancerApiVersion = '2022-07-01'
var vnetApiVersion = '2022-07-01'
var publicIPVersion = '2022-07-01'
var ddosProtectionPlanName = 'ddosProtectionPlan'

// DDoS Protection Plan
resource ddosProtectionPlan 'Microsoft.Network/ddosProtectionPlans@2022-07-01' = {
  name: ddosProtectionPlanName
  location: location
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
  location: location
  properties: {
    sku: 'Standard'
    containers: [
      {
        name: 'web'
        properties: {
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
          volumeMounts: [
            {
              name: 'cachevolume'
              mountPath: '/mnt/cache' // ephemeral volume path in container filesystem
            }
          ]
        }
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
  }
}

// NGroups
resource nGroups 'Microsoft.ContainerInstance/NGroups@2024-09-01-preview' = {
  name: nGroupsName
  location: location
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
