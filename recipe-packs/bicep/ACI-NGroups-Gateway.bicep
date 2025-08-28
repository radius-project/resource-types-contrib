@description('Container Instance API version')
@maxLength(32)
param apiVersion string = '2024-09-01-preview'

@description('NGroups parameter name')
@maxLength(64)
param nGroupsNameParam string = 'nGroups_lin100_regional_ag'

@description('Container Group Profile name')
@maxLength(64)
param containerGroupProfileName string = 'cgp'

@description('Application Gateway name')
@maxLength(64)
param applicationGatewayName string = 'agw1'

@description('Public IP name')
@maxLength(64)
param publicIPName string = 'publicIP'

@description('Backend Address Pool name')
@maxLength(64)
param backendAddressPoolName string = 'bepool'

@description('Virtual Network name')
@maxLength(64)
param vnetName string = 'vnet1'

@description('Network Security Group name')
@maxLength(64)
param networkSecurityGroupName string = 'nsg1'

@description('Desired container count')
param desiredCount int = 100

@description('Maintain desired count')
param maintainDesiredCount bool = true

@description('Availability zones')
param zones array = []

@description('Virtual Network address prefix')
@maxLength(64)
param vnetAddressPrefix string = '172.16.0.0/23'

@description('ACI Subnet address prefix')
@maxLength(64)
param aciSubnetAddressPrefix string = '172.16.0.0/25'

@description('Application Gateway Subnet address prefix')
@maxLength(64)
param appGatewaySubnetAddressPrefix string = '172.16.1.0/25'

@description('ACI Subnet name')
@maxLength(64)
param aciSubnetName string = 'aciSubnet'

@description('Application Gateway Subnet name')
@maxLength(64)
param appGatewaySubnetName string = 'appgatewaySubnet'

@description('DDoS Protection Plan name')
@maxLength(64)
param ddosProtectionPlanName string = 'ddosProtectionPlan'

// Variables
var resourcePrefix = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/'
var applicationGatewayApiVersion = '2022-09-01'
var prefixCG = 'cg-lin100-regional-ag-'

// Network Security Group
resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2022-09-01' = {
  name: networkSecurityGroupName
  location: resourceGroup().location
  properties: {
    securityRules: [
      {
        name: 'AppGatewayV2ProbeInbound'
        properties: {
          access: 'Allow'
          description: 'Allow traffic from GatewayManager. This rule is needed for application gateway probes to work.'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
          direction: 'Inbound'
          protocol: 'Tcp'
          priority: 100
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
        }
      }
      {
        name: 'AllowHTTPInbound'
        properties: {
          access: 'Allow'
          description: 'Allow Internet traffic on port 80'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
          direction: 'Inbound'
          protocol: 'Tcp'
          priority: 110
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
        }
      }
      {
        name: 'AllowPublicIPAddress'
        properties: {
          access: 'Allow'
          description: 'Allow traffic from public ip address'
          destinationAddressPrefix: publicIPAddress.properties.ipAddress
          destinationPortRange: '80'
          direction: 'Inbound'
          protocol: 'Tcp'
          priority: 111
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
        }
      }
      {
        name: 'AllowVirtualNetworkInbound'
        properties: {
          access: 'Allow'
          description: 'Allow Internet traffic to Virtual network'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '80'
          direction: 'Inbound'
          protocol: '*'
          priority: 112
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
        }
      }
    ]
  }
}

// Public IP Address
resource publicIPAddress 'Microsoft.Network/publicIPAddresses@2022-09-01' = {
  name: publicIPName
  location: resourceGroup().location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 5
    ipTags: []
    ddosSettings: {
      protectionMode: 'VirtualNetworkInherited'
    }
  }
}

// Virtual Network
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2022-09-01' = {
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
        name: appGatewaySubnetName
        id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, appGatewaySubnetName)
        properties: {
          addressPrefix: appGatewaySubnetAddressPrefix
          applicationGatewayIPConfigurations: [
            {
              id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/gatewayIPConfigurations/appGatewayIpConfig'
            }
          ]
          serviceEndpoints: []
          delegations: []
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
        type: 'Microsoft.Network/virtualNetworks/subnets'
      }
      {
        name: aciSubnetName
        id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, aciSubnetName)
        properties: {
          addressPrefix: aciSubnetAddressPrefix
          serviceEndpoints: []
          delegations: [
            {
              name: 'ACIDelegationService'
              id: '${resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, aciSubnetName)}/delegations/ACIDelegationService'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
              type: 'Microsoft.Network/virtualNetworks/subnets/delegations'
            }
          ]
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
        type: 'Microsoft.Network/virtualNetworks/subnets'
      }
    ]
    virtualNetworkPeerings: []
    enableDdosProtection: false
  }
  dependsOn: [
    networkSecurityGroup
  ]
}

// ACI Subnet (separate resource for proper dependency management)
resource aciSubnet 'Microsoft.Network/virtualNetworks/subnets@2022-09-01' = {
  parent: virtualNetwork
  name: aciSubnetName
  properties: {
    addressPrefix: aciSubnetAddressPrefix
    serviceEndpoints: []
    delegations: [
      {
        name: 'ACIDelegationService'
        id: '${resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, aciSubnetName)}/delegations/ACIDelegationService'
        properties: {
          serviceName: 'Microsoft.ContainerInstance/containerGroups'
        }
        type: 'Microsoft.Network/virtualNetworks/subnets/delegations'
      }
    ]
    networkSecurityGroup: {
      id: networkSecurityGroup.id
    }
    privateEndpointNetworkPolicies: 'Disabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

// Application Gateway Subnet (separate resource for proper dependency management)
resource appGatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2022-09-01' = {
  parent: virtualNetwork
  name: appGatewaySubnetName
  properties: {
    addressPrefix: appGatewaySubnetAddressPrefix
    applicationGatewayIPConfigurations: [
      {
        id: '${applicationGateway.id}/gatewayIPConfigurations/appGatewayIpConfig'
      }
    ]
    networkSecurityGroup: {
      id: networkSecurityGroup.id
    }
    privateEndpointNetworkPolicies: 'Disabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

// Application Gateway
resource applicationGateway 'Microsoft.Network/applicationGateways@2022-09-01' = {
  name: applicationGatewayName
  location: resourceGroup().location
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/gatewayIPConfigurations/appGatewayIpConfig'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, appGatewaySubnetName)
          }
        }
      }
    ]
    sslCertificates: []
    trustedRootCertificates: []
    trustedClientCertificates: []
    sslProfiles: []
    frontendIPConfigurations: [
      {
        name: 'appGwPublicFrontendIpIPv4'
        id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/frontendIPConfigurations/appGwPublicFrontendIpIPv4'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIPAddress.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port_80'
        id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/frontendPorts/port_80'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: backendAddressPoolName
        id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/backendAddressPools/${backendAddressPoolName}'
        properties: {
          backendAddresses: []
        }
      }
    ]
    loadDistributionPolicies: []
    backendHttpSettingsCollection: [
      {
        name: '${applicationGatewayName}-be-settings'
        id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/backendHttpSettingsCollection/${applicationGatewayName}-be-settings'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: false
          requestTimeout: 60
          probe: {
            id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/probes/healthprobe'
          }
        }
      }
    ]
    backendSettingsCollection: []
    httpListeners: [
      {
        name: '${applicationGatewayName}-listener'
        id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/httpListeners/${applicationGatewayName}-listener'
        properties: {
          frontendIPConfiguration: {
            id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/frontendIPConfigurations/appGwPublicFrontendIpIPv4'
          }
          frontendPort: {
            id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/frontendPorts/port_80'
          }
          protocol: 'Http'
          hostNames: []
          requireServerNameIndication: false
          customErrorConfigurations: []
        }
      }
    ]
    listeners: []
    urlPathMaps: []
    requestRoutingRules: [
      {
        name: '${applicationGatewayName}-routerule'
        id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/requestRoutingRules/${applicationGatewayName}-routerule'
        properties: {
          ruleType: 'Basic'
          priority: 1
          httpListener: {
            id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/httpListeners/${applicationGatewayName}-listener'
          }
          backendAddressPool: {
            id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/backendAddressPools/${backendAddressPoolName}'
          }
          backendHttpSettings: {
            id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/backendHttpSettingsCollection/${applicationGatewayName}-be-settings'
          }
        }
      }
    ]
    routingRules: []
    probes: [
      {
        name: 'healthprobe'
        id: '${resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)}/probes/healthprobe'
        properties: {
          protocol: 'Http'
          host: '127.0.0.1'
          path: '/'
          interval: 3600
          timeout: 3600
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          minServers: 0
          match: {}
        }
      }
    ]
    rewriteRuleSets: []
    redirectConfigurations: []
    privateLinkConfigurations: []
    enableHttp2: false
    autoscaleConfiguration: {
      minCapacity: 0
      maxCapacity: 3
    }
  }
  dependsOn: [
    appGatewaySubnet
    publicIPAddress
  ]
}

// Container Group Profile
resource containerGroupProfile 'Microsoft.ContainerInstance/containerGroupProfiles@2024-09-01-preview' = {
  name: containerGroupProfileName
  location: resourceGroup().location
  properties: {
    sku: 'Standard'
    containers: [
      {
        name: 'web'
        properties: {
          image: 'mcr.microsoft.com/azuredocs/aci-helloworld@sha256:565dba8ce20ca1a311c2d9485089d7ddc935dd50140510050345a1b0ea4ffa6e'
          ports: [
            {
              protocol: 'TCP'
              port: 80
            }
          ]
          resources: {
            requests: {
              memoryInGB: json('1.0')
              cpu: json('1.0')
            }
          }
        }
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
  name: nGroupsNameParam
  location: resourceGroup().location
  zones: zones
  properties: {
    elasticProfile: {
      desiredCount: desiredCount
      maintainDesiredCount: maintainDesiredCount
      containerGroupNamingPolicy: {
        guidNamingPolicy: {
          prefix: prefixCG
        }
      }
    }
    containerGroupProfiles: [
      {
        resource: {
          id: '${resourcePrefix}Microsoft.ContainerInstance/containerGroupProfiles/${containerGroupProfileName}'
        }
        containerGroupProperties: {
          subnetIds: [
            {
              id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, aciSubnetName)
              name: aciSubnetName
            }
          ]
        }
        networkProfile: {
          applicationGateway: {
            resource: {
              id: applicationGateway.id
            }
            backendAddressPools: [
              {
                resource: {
                  id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', applicationGatewayName, backendAddressPoolName)
                }
              }
            ]
          }
        }
      }
    ]
  }
  tags: {
    cirrusTestScenario: 'lin-100.regional.appgateway'
    'reprovision.enabled': true
  }
  dependsOn: [
    containerGroupProfile
    applicationGateway
    virtualNetwork
  ]
}

// Outputs
output virtualNetworkId string = virtualNetwork.id
output aciSubnetId string = aciSubnet.id
output appGatewaySubnetId string = appGatewaySubnet.id
output applicationGatewayId string = applicationGateway.id
output backendAddressPoolId string = applicationGateway.properties.backendAddressPools[0].id
output publicIPId string = publicIPAddress.id
output publicIPAddress string = publicIPAddress.properties.ipAddress
output networkSecurityGroupId string = networkSecurityGroup.id
output containerGroupProfileId string = containerGroupProfile.id
output nGroupsId string = nGroups.id
output frontendIPConfigurationId string = applicationGateway.properties.frontendIPConfigurations[0].id
output httpListenerId string = applicationGateway.properties.httpListeners[0].id
output healthProbeId string = applicationGateway.properties.probes[0].id
