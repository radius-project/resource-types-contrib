param context object

var secretName = context.resource.name
var secretData = context.resource.properties.data

// ---------------------------------------------------------------------------
// Azure Key Vault – stores each key in the Radius secret as a Key Vault
// secret.  Secrets are created via the ARM management plane (child resources),
// so no access policies or RBAC are needed – Contributor on the RG suffices.
// ---------------------------------------------------------------------------
resource vault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: 'kv-${uniqueString(secretName, resourceGroup().id)}'
  location: resourceGroup().location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableSoftDelete: true
    enableRbacAuthorization: false
    accessPolicies: []
  }
}

// Store each entry from the Radius secret data map as a Key Vault secret.
resource kvSecrets 'Microsoft.KeyVault/vaults/secrets@2022-07-01' = [
  for item in items(secretData): {
    parent: vault
    name: item.key
    properties: {
      value: item.value.value
    }
  }
]

output result object = {
  resources: [vault.id]
}
