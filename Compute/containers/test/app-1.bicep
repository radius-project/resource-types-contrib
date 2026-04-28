extension radius
extension radiusResources
extension persistentVolumes
extension secrets

param environment string

// Secure parameters with test defaults 
#disable-next-line secure-parameter-default @secure()
param username string = 'admin'
#disable-next-line secure-parameter-default @secure()
param password string = 'c2VjcmV0cGFzc3dvcmQ='
#disable-next-line secure-parameter-default @secure()
param apiKey string = 'abc123xyz'
@description('Container image. Must define a valid ENTRYPOINT/CMD. Defaults to nginx image.')
param image string = 'nginx:latest'

@description('Optional init container image. If empty, init container is not used.')
param initImage string = 'busybox:latest'

// TODO: Switch to Radius.Core/applications once runtime resolves Radius.Core app references
// Tracked in: https://github.com/radius-project/resource-types-contrib/issues/109
resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'containers-testapp'
  location: 'global'
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
      secrets: {
        source: secret.id
        disableDefaultEnvVars: false
      }
    }
    containers: {
      demo: {        
        image: image        
        ports: {
          http: {
            containerPort: 80
            protocol: 'TCP'
          }
        }
        env: {
          CONNECTIONS_SECRET_USERNAME: {
            valueFrom: {
              secretKeyRef: {
                secretName: 'secret.name1'
                key: 'username'
              }
            }
          }
          CONNECTIONS_SECRET_APIKEY: {
            valueFrom: {
              secretKeyRef: {
                secretName: 'secret.name2'
                key: 'apikey'
              }
            }
          }
          CONNECTIONS_SECRET_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: 'secret.name3'
                key: 'password'
              }
            }
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
          {
            volumeName: 'secrets'
            mountPath: '/etc/secrets'
          }
        ] 
        resources: {
          requests: {
            cpu: '1.0'       
            memoryInMib: 1024   
          }
          limits: {
            cpu: '2.0'
            memoryInMib: 2048
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
        image: initImage
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
            cpu: '1.0'
            memoryInMib: 1024
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
      secrets: {
        secretName: secret.name
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

resource secret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'app-secrets-${uniqueString(deployment().name)}'
  properties: {
    environment: environment
    application: app.id
    data: {
      username: {
        value: username
      }
      password: {
        value: password
        encoding: 'base64'
      }
      apikey: {
        value: apiKey
      }
    }
  }
}
