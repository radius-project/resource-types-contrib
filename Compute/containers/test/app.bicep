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
        disableDefaultEnvVars: false
      }
    }
    containers: {
      web: {
        image: 'nginx:alpine'
        command: ['/bin/sh', '-c']
        args: ['nginx -g "daemon off;"']
        workingDir: '/usr/share/nginx/html'
        ports: {
          http: {
            containerPort: 80
            protocol: 'TCP'
          }
        }
        env: {
          TEST_ENV: {
            value: 'testenv'
          }
          MAX_CONNECTIONS: {
            value: '100'
          }
          NGINX_HOST: {
            value: 'localhost'
          }
        }
        volumeMounts: [
          {
            volumeName: 'data'
            mountPath: '/app/data'
          }
          {
            volumeName: 'cache'
            mountPath: '/tmp/cache'
          }
        ] 
        resources: {
          requests: {
            cpu: '0.1'       
            memoryInMib: 128   
          }
          limits: {
            cpu: '0.5'
            memoryInMib: 512
          }
        }
        livenessProbe: {
          httpGet: {
            path: '/'
            port: 80
            scheme: 'http'
          }
          initialDelaySeconds: 10
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
          successThreshold: 1
        }
        readinessProbe: {
          httpGet: {
            path: '/'
            port: 80
          }
          initialDelaySeconds: 5
          periodSeconds: 10
        }
      }
      init: {
        initContainer: true
        image: 'busybox:latest'
        command: ['sh', '-c']
        args: ['echo "Initializing..." && sleep 5']
        workingDir: '/tmp'
        env: {
          INIT_MESSAGE: {
            value: 'Starting initialization'
          }
        }
        resources: {
          requests: {
            cpu: '0.1'
            memoryInMib: 64
          }
        }
      }
    }
    restartPolicy: 'Always'
    volumes: {
      data: {
        persistentVolume: {
          resourceId: myPersistentVolume.id
          accessMode: 'ReadWriteOnce'
        }
      }
      cache: {
        emptyDir: {
          medium: 'memory'
        }
      }
    }
    extensions: {
      daprSidecar: {
        appId: 'myapp'
        appPort: 80
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
  name: 'mypersistentvolume'
  properties: {
    environment: environment
    application: app.id
    sizeInGib: 1
  }
}
