// Variables (using var instead of parameters since the ARM template uses variables)
var cgProfileName = 'cgp_1'
var nGroupsName = 'ngroup_confidential_basic'
var apiVersion = '2024-09-01-preview'
var desiredCount = 1
var prefixCG = 'cg-confidential-'
var resourcePrefix = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/'

// Container Group Profile with Confidential Computing
resource containerGroupProfile 'Microsoft.ContainerInstance/containerGroupProfiles@2024-09-01-preview' = {
  name: cgProfileName
  location: resourceGroup().location
  properties: {
    sku: 'Confidential'
    confidentialComputeProperties: {
      ccePolicy: ''
    }
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
      type: 'Public'
    }
    osType: 'Linux'
  }
}

// NGroups for Confidential Computing
resource nGroups 'Microsoft.ContainerInstance/NGroups@2024-09-01-preview' = {
  name: nGroupsName
  location: resourceGroup().location
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
    cirrusTestScenario: 'confidential-1.basic'
  }
  dependsOn: [
    containerGroupProfile
  ]
}

// Outputs
output containerGroupProfileId string = containerGroupProfile.id
output nGroupId string = nGroups.id

output result object = {
  values: {
    containerGroupProfileId: containerGroupProfile.id
    nGroupsId: nGroups.id
    location: resourceGroup().location
    desiredCount: desiredCount
  }
}
