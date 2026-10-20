extension radius

@description('The ID of the Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Application name. CI supplies a unique name for deployment and cleanup.')
param applicationName string = 'persistentvolumes-test'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

resource volume 'Radius.Compute/persistentVolumes@2025-08-01-preview' = {
  name: 'testvolume'
  properties: {
    environment: environment
    application: app.id
    sizeInGib: 1
    allowedAccessModes: 'ReadWriteOnce'
  }
}
