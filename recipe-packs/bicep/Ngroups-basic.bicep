// Variables
var cgProfileName = 'cgp_1'
var nGroupsName = 'ngroup_lin1_basic'
var apiVersion = '2024-09-01-preview'
var desiredCount = 1
var prefixCG = 'cg-lin1-basic-'
var resourcePrefix = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/'

// Container Group Profile
resource containerGroupProfile 'Microsoft.ContainerInstance/containerGroupProfiles@2024-09-01-preview' = {
  name: cgProfileName
  location: resourceGroup().location
  properties: {
    sku: 'Standard'
    containers: [
      {
        name: 'aci-helloworld'
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
              memoryInGB: 1.0
              cpu: 1.0
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
      type: 'Public'
    }
    osType: 'Linux'
  }
}

// NGroups resource
resource nGroups 'Microsoft.ContainerInstance/NGroups@2024-09-01-preview' = {
  name: nGroupsName
  location: resourceGroup().location
  dependsOn: [
    containerGroupProfile
  ]
  properties: {
    elasticProfile: {
      desiredCount: desiredCount
      containerGroupNamingPolicy: {
        guidNamingPolicy: {
          prefix: prefixCG
        }
      }
    }
    containerGroupProfiles: [
      {
        resource: {
          id: '${resourcePrefix}Microsoft.ContainerInstance/containerGroupProfiles/${cgProfileName}'
        }
      }
    ]
  }
  tags: {
    cirrusTestScenario: 'lin-1.basic'
  }
}
