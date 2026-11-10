@description('The Radius resource context.')
param context object

@description('Azure OpenAI account name. The Azure AKS pack supplies its existing resource-name hash.')
param openAIAccountName string = 'oai-${uniqueString(resourceGroup().id, context.resource.id)}'

@description('Azure region for the account. Defaults to the resource group location.')
param location string = resourceGroup().location

// Complete the account and its key outputs before any model deployment starts.
module account 'br:mcr.microsoft.com/bicep/avm/res/cognitive-services/account:0.15.0' = {
  name: 'openai-account-${uniqueString(resourceGroup().id, openAIAccountName)}'
  params: {
    name: openAIAccountName
    location: location
    kind: 'OpenAI'
    sku: 'S0'
    customSubDomainName: openAIAccountName
    disableLocalAuth: false
    publicNetworkAccess: 'Enabled'
    deployments: []
    enableTelemetry: false
    lock: {
      kind: 'None'
    }
  }
}

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  name: '${openAIAccountName}/chat'
  properties: {
    model: {
      format: 'OpenAI'
      name: context.resource.properties.?model ?? 'gpt-5-mini'
      version: '2025-08-07'
    }
  }
  sku: {
    name: 'GlobalStandard'
    capacity: 1
  }
  dependsOn: [
    account
  ]
}

@secure()
output result object = {
  resources: [
    account.outputs.resourceId
    modelDeployment.id
  ]
  values: {
    endpoint: account.outputs.endpoint
  }
  secrets: {
    apiKey: account.outputs.primaryKey!
  }
}
