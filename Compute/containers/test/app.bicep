extension radius
extension containers
extension persistentVolumes

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'containers-testapp'
  properties: {
    environment: environment
  }
}

// Create a container that mounts the persistent volume
resource myContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'myapp'
  properties: {
    environment: environment
    application: app.id
    connections: {
      data: {
        source: myPersistentVolume.id
      }
    }
    containers: {
      web: {
        image: 'nginx:alpine'
        ports: {
          http: {
            containerPort: 80
          }
        }
        volumeMounts: [
          {
            volumeName: 'data'
            mountPath: '/app/data'
          } 
        ] 
        resources: {
          requests: {
            cpu: '0.1'       
            memoryInMib: 128   
          }
        }
      }
    }
    volumes: {
      data: {
        persistentVolume: {
          resourceId: myPersistentVolume.id
          accessMode: 'ReadWriteOnce'
        }
      }
    }
    replicas: 1
    autoScaling: {
      maxReplicas: 3
      metrics: [
        {
          kind: 'cpu'
          target: {
            averageUtilization: 50
          }
        }
      ]
    }
  }
}

resource myPersistentVolume 'Radius.Compute/persistentVolumes@2025-08-01-preview' = {
  name: 'myPersistentVolume'
  properties: {
    environment: environment
    application: app.id
    sizeInGib: 1
  }
}
