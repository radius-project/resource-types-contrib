extension radius

@description('The Radius Environment ID. Set automatically by the rad CLI.')
param environment string

@description('Unique application name supplied by the test helper.')
param applicationName string

@description('Unique resource name whose matching credentials Secret is created by the test helper.')
param objectStorageResourceName string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

resource store 'Radius.Storage/objectStorage@2025-08-01-preview' = {
  name: objectStorageResourceName
  properties: {
    environment: environment
    application: app.id
    containerName: 'app-files'
  }
}
