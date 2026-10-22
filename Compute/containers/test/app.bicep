extension radius
extension containers

param environment string

@description('Application name. CI supplies a unique name for deployment and cleanup.')
param applicationName string = 'containers-testapp'

// Use official image mirrors to avoid anonymous Docker Hub pulls in cloud tests.
var nginxImage = 'public.ecr.aws/docker/library/nginx@sha256:a3554c0d0b48177b1413c26e01f695334428020d9df01243fbae3e11cfd17417'
var busyboxImage = 'public.ecr.aws/docker/library/busybox@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e'

// Secure parameters with test defaults 
#disable-next-line secure-parameter-default @secure()
param username string = 'admin'
#disable-next-line secure-parameter-default @secure()
param password string = 'secretpassword'
#disable-next-line secure-parameter-default @secure()
param apiKey string = 'abc123xyz'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

// Create a container that mounts the persistent volume
resource myContainer 'containers:Radius.Compute/containers@2025-08-01-preview' = {
  name: 'myApp'
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
      orderProcessor: {
        image: nginxImage
        command: ['/bin/sh', '-c']
        args: ['nginx -g "daemon off;"']
        workingDir: '/usr/share/nginx/html'
        ports: {
          httpPort: {
            containerPort: 80
            protocol: 'TCP'
          }
        }
        env: {
          CONNECTIONS_SECRET_USERNAME: {
            valueFrom: {
              secretKeyRef: {
                secretName: secret.name
                key: 'username'
              }
            }
          }
          CONNECTIONS_SECRET_APIKEY: {
            valueFrom: {
              secretKeyRef: {
                secretName: secret.name
                key: 'apikey'
              }
            }
          }
          CONNECTIONS_SECRET_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: secret.name
                key: 'password'
              }
            }
          }
          // Exercise the read-only `hosts` map of a peer container: it maps each
          // port-exposing container name to its Kubernetes Service DNS host. Populated
          // by the Kubernetes recipe; safe-navigated so the reference is an empty string
          // on platforms that do not emit it.
          PEER_HOST: {
            value: noConnectionsContainer.properties.?hosts.?simple ?? ''
          }
        }
        volumeMounts: [
          {
            volumeName: 'appData'
            mountPath: '/app/data'
          }
          {
            volumeName: 'cacheData'
            mountPath: '/tmp/cache'
          }
          {
            volumeName: 'appSecrets'
            mountPath: '/etc/secrets'
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
      dbMigration: {
        initContainer: true
        image: busyboxImage
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
      appData: {
        persistentVolume: {
          resourceId: myPersistentVolume.id
          accessMode: 'ReadWriteOnce'
        }
      }
      cacheData: {
        emptyDir: {
          medium: 'memory'
        }
      }
      appSecrets: {
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

// Container with no connections - validates that the recipe handles missing connections gracefully
resource noConnectionsContainer 'containers:Radius.Compute/containers@2025-08-01-preview' = {
  name: 'no-connections-app'
  properties: {
    environment: environment
    application: app.id
    containers: {
      simple: {
        image: nginxImage
        ports: {
          http: {
            containerPort: 80
          }
        }
      }
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
        value: base64(password)
        encoding: 'base64'
      }
      apikey: {
        value: apiKey
      }
    }
  }
}
