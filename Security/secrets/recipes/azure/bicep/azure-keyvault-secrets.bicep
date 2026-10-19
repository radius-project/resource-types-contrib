// ---------------------------------------------------------------------------
// Radius Azure ACI Key Vault Secrets Recipe
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('The Radius resource context object containing resource properties and metadata.')
param context object

@description('Azure region for new resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Changes on each deployment so that the deployment script writes the current secret values to Key Vault. Do not set this parameter.')
param scriptUpdateTag string = utcNow()

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

// Uses a short prefix + uniqueString hash to stay within the 3–24 char Key Vault name limit.
var keyVaultName = 'kv-${take(context.resource.name, 7)}-${uniqueString(context.resource.id, resourceGroup().id)}'
var identityName = context.resource.name

// If secretKind is not set, set to 'generic'
var secretKind = context.resource.properties.?kind ?? 'generic'

// Secret data sourced entirely from the Radius context object – not hardcoded.
// Falls back to an empty object when data is missing or null.
var secretData = contains(context.resource.properties, 'data') && context.resource.properties.data != null ? context.resource.properties.data : {}

// Validate required fields for secret kinds (matching K8s recipe parity)
var missingFields = secretKind == 'certificate-pem' && (!contains(secretData, 'tls.crt') || !contains(secretData, 'tls.key'))
  ? 'certificate-pem secrets must contain keys `tls.crt` and `tls.key`'
  : secretKind == 'basicAuthentication' && (!contains(secretData, 'username') || !contains(secretData, 'password'))
  ? 'basicAuthentication secrets must contain keys `username` and `password`'
  : secretKind == 'azureWorkloadIdentity' && (!contains(secretData, 'clientId') || !contains(secretData, 'tenantId'))
  ? 'azureWorkloadIdentity secrets must contain keys `clientId` and `tenantId`'
  : secretKind == 'awsIRSA' && !contains(secretData, 'roleARN')
  ? 'awsIRSA secrets must contain key `roleARN`'
  : ''

// Use the validation error as the vault name to surface it clearly during deployment
var effectiveKeyVaultName = length(missingFields) > 0 ? missingFields : keyVaultName

// Resolves the raw secret value with null safety.
var rawSecretValues = [for item in items(secretData): {
  name: item.key
  rawValue: item.value != null && contains(item.value, 'value') && item.value.value != null ? item.value.value : ''
  needsBase64: item.value != null && contains(item.value, 'encoding') && item.value.encoding == 'base64'
}]

// If encoding is 'base64', the plain-text value is base64-encoded before storage.
var secretItems = [for item in rawSecretValues: {
  name: item.name
  value: item.needsBase64 ? base64(item.rawValue) : item.rawValue
}]

// Built-in role: Key Vault Administrator – grants full access to all Key Vault data-plane operations.
var keyVaultAdministratorRoleId = '00482a5a-887f-4fb3-b363-3b7fe8e74483'

// Deterministic GUID for the role assignment prevents redeploy churn.
var roleAssignmentName = guid(keyVault.id, uai.id, keyVaultAdministratorRoleId)

// ---------------------------------------------------------------------------
// Key Vault
// ---------------------------------------------------------------------------
// Creates a new vault in the same resource group as the recipe deployment.
// RBAC authorization is enabled so role assignments (not access policies)
// govern data-plane access.

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: effectiveKeyVaultName
  location: location
  tags: {
    'radius-resource': context.resource.name
    'radius-application': context.application == null ? '' : context.application.name
  }
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
  }
}

// ---------------------------------------------------------------------------
// User Assigned Managed Identity
// ---------------------------------------------------------------------------


resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: {
    'radius-resource': context.resource.name
    'radius-application': context.application == null ? '' : context.application.name
  }
}

// ---------------------------------------------------------------------------
// RBAC – Key Vault Administrator role assignment
// ---------------------------------------------------------------------------
// Grants the UAI the "Key Vault Administrator" role (full data-plane access)
// scoped to this Key Vault only.

resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: roleAssignmentName
  scope: keyVault
  properties: {
    principalId: uai.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultAdministratorRoleId)
  }
}

// ---------------------------------------------------------------------------
// Write secrets into Key Vault
// ---------------------------------------------------------------------------
// A deployment script writes each entry of context.resource.properties.data
// to the Key Vault. The recipe does not declare
// 'Microsoft.KeyVault/vaults/secrets' resources, because Radius deletes each
// resource that the recipe deploys, and Azure Resource Manager does not
// support DELETE on Key Vault secrets (405 DeleteNotSupported). That made
// the recipe delete fail. The secrets are removed when the Key Vault is
// deleted.
//
// The script runs as the UAI, which has the Key Vault Administrator role on
// the vault. The script retries because the role assignment can take some
// minutes to propagate.

resource kvSecretsScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = if (length(secretItems) > 0) {
  name: 'kv-secrets-${uniqueString(context.resource.id, resourceGroup().id)}'
  location: location
  kind: 'AzureCLI'
  tags: {
    'radius-resource': context.resource.name
    'radius-application': context.application == null ? '' : context.application.name
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uai.id}': {}
    }
  }
  dependsOn: [
    kvRoleAssignment
  ]
  properties: {
    azCliVersion: '2.63.0'
    forceUpdateTag: scriptUpdateTag
    retentionInterval: 'PT1H'
    timeout: 'PT20M'
    cleanupPreference: 'Always'
    environmentVariables: [
      {
        name: 'KEY_VAULT_NAME'
        value: keyVault.name
      }
      {
        name: 'SECRET_ITEMS'
        #disable-next-line use-secure-value-for-secure-inputs
        secureValue: string(secretItems)
      }
    ]
    scriptContent: '''
#!/bin/bash
set -euo pipefail

max_attempts=30
printf '%s' "$SECRET_ITEMS" | jq -r '.[] | "\(.name) \(.value | @base64)"' |
  while read -r name encoded; do
    # Keep trailing newlines in the value (for example, PEM certificates).
    value="$(printf '%s' "$encoded" | base64 -d; printf x)"
    value="${value%x}"
    attempt=1
    until az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "$name" \
      --content-type text/plain --value="$value" --output none; do
      if [ "$attempt" -ge "$max_attempts" ]; then
        echo "Failed to set secret '$name' after $attempt attempts." >&2
        exit 1
      fi
      echo "Could not set secret '$name' (attempt $attempt). The role assignment may not be active yet. Retrying in 20 seconds."
      attempt=$((attempt + 1))
      sleep 20
    done
    echo "Set secret '$name'."
  done
'''
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Resource ID of the created Azure Key Vault.')
output keyVaultId string = keyVault.id

@description('URI of the created Azure Key Vault (used by Azure SDK to connect).')
output keyVaultUri string = keyVault.properties.vaultUri

@description('Resource ID of the User Assigned Managed Identity.')
output userAssignedIdentityId string = uai.id

@description('Client ID of the User Assigned Managed Identity (used in application code).')
output userAssignedIdentityClientId string = uai.properties.clientId

@description('Principal (object) ID of the User Assigned Managed Identity.')
output userAssignedIdentityPrincipalId string = uai.properties.principalId

// Radius recipe result 
output result object = {
  resources: [
    uai.id
    keyVault.id
  ]
  values: {
    keyVaultId: keyVault.id
    keyVaultUri: keyVault.properties.vaultUri
    userAssignedIdentityId: uai.id
    userAssignedIdentityClientId: uai.properties.clientId
    userAssignedIdentityPrincipalId: uai.properties.principalId
  }
}
