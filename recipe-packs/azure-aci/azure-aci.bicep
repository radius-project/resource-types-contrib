extension radius

resource azureAciRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aci'
  properties: {
    // Pin the verified recipe revision; latest can lag the ACI identity/result fixes.
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-aci-recipes/containers:31e17276ac5261b6c22a375edbc3122b9a09b6ea'
      }
      'Radius.Compute/persistentVolumes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-aci-recipes/persistentvolumes:31e17276ac5261b6c22a375edbc3122b9a09b6ea'
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-aci-recipes/secrets:31e17276ac5261b6c22a375edbc3122b9a09b6ea'
      }
    }
  }
}
