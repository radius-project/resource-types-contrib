extension radius
extension containers
extension persistentVolumes

param environment string

// This is simple application with only contianer and persistent volume
// resources to test PV creation and mounting in container.
resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'acipvtest-app'
  properties: {
    environment: environment
  }
}

resource pv 'Radius.Compute/persistentVolumes@2025-08-01-preview' = {
  name: 'acipvtest-pv'
  properties: {
    environment: environment
    application: app.id
    sizeInGib: 5
  }
}

resource myContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'acipvtest-container'
  properties: {
    environment: environment
    application: app.id
    containers: {
      demo: {
        image: 'mcr.microsoft.com/azuredocs/aci-helloworld:latest'
        ports: {
          http: {
            containerPort: 80
            protocol: 'TCP'
          }
        }
        volumeMounts: [
          {
            volumeName: 'data' // should match with the name of the volume defined in the container spec/recipe (eg. azure-aci-containers.bicep)
            mountPath: '/mnt/fileshare'
          }
        ]
      }
    }
    volumes: {
      data: {
        persistentVolume: {
          resourceId: pv.id
          accessMode: 'ReadWriteOnce'
        }
      }
    }  
    connections: {
      data: {
        source: pv.id
      }
    }  
  }  
}
