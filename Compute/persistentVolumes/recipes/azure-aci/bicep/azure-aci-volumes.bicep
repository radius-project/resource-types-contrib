
targetScope = 'resourceGroup'

@description('Radius context object passed into the recipe.')
param context object

@description('Azure region for recipe resources. Defaults to the current resource group location.')
param location string = resourceGroup().location

@description('Storage account SKU for Azure Files.')
param storageSku string = 'Standard_LRS'

@description('Storage account kind.')
param storageKind string = 'StorageV2'

var storageAccountName = toLower('pv${take(uniqueString(context.resource.id), 22)}')
var fileShareName = toLower('pv${take(uniqueString('${context.resource.id}/share'), 22)}')
var shareQuotaGiB = int(context.resource.properties.sizeInGib)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: storageSku
  }
  kind: storageKind
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: fileShareName
  properties: {
    shareQuota: shareQuotaGiB
    enabledProtocols: 'SMB'
    accessTier: 'TransactionOptimized'
  }
}

output result object = {
  resources: [
    storageAccount.id
    fileShare.id
  ]
  values: {
    provider: 'azureFile'
    storageAccountName: storageAccount.name
    shareName: fileShare.name
    shareQuotaGiB: shareQuotaGiB
    allowedAccessModes: context.resource.properties.?allowedAccessModes ?? ''
  }
  secrets: {
    #disable-next-line outputs-should-not-contain-secrets
    storageAccountKey: storageAccount.listKeys().keys[0].value
  }
}
