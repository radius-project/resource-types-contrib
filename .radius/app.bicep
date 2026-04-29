extension radius

param environment string

resource resourceTypesContribApp 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'resource-types-contrib'
  properties: {
    environment: environment
  }
}
