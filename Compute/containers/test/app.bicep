extension radius

param environment string

// Secure parameters with test defaults 
#disable-next-line secure-parameter-default @secure()
param username string = 'admin'
#disable-next-line secure-parameter-default @secure()
param password string = 'c2VjcmV0cGFzc3dvcmQ='
#disable-next-line secure-parameter-default @secure()
param apiKey string = 'abc123xyz'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'containers-testapp'
  properties: {
    environment: environment
  }
}

// Create a container that mounts the persistent volume
resource myContainer 'Radius.Compute/containers@2025-08-01-preview' = {
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
        image: 'nginx:alpine'
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
resource noConnectionsContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'no-connections-app'
  properties: {
    environment: environment
    application: app.id
    containers: {
      simple: {
        image: 'nginx:alpine'
        ports: {
          http: {
            containerPort: 80
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Issue #135 regression coverage: predictable service-to-service DNS.
//
// The containers recipe emits a short-name alias Service equal to the container
// resource name, so a peer must be reachable at http://<resource-name>:<port>.
// `dnsServer` (resource name `dns-server`) exposes port 80. `dnsClient` has an
// init container that blocks until it can reach the server by that exact
// resource-name DNS (`http://dns-server:80`). If the alias Service is missing
// (the bug this fix addresses), the init container never succeeds, the client
// pod never becomes ready, and this test deployment fails.
// ---------------------------------------------------------------------------
resource dnsServer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'dns-server'
  properties: {
    environment: environment
    application: app.id
    containers: {
      server: {
        image: 'nginx:alpine'
        ports: {
          web: {
            containerPort: 80
            protocol: 'TCP'
          }
        }
      }
    }
  }
}

resource dnsClient 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'dns-client'
  properties: {
    environment: environment
    application: app.id
    containers: {
      // Blocks until the server resolves by its resource-name DNS. Retries for
      // up to ~120s so the server has time to come up in the same deployment.
      waitForServer: {
        initContainer: true
        image: 'busybox:latest'
        command: ['sh', '-c']
        args: [
          'echo "Resolving peer by resource name (issue #135)..."; for i in $(seq 1 60); do if wget -q -T 2 -O /dev/null http://dns-server:80; then echo "Reached http://dns-server:80 by resource-name DNS"; exit 0; fi; echo "attempt $i: dns-server not reachable yet"; sleep 2; done; echo "FAILED: could not reach http://dns-server:80 by resource-name DNS"; exit 1'
        ]
      }
      client: {
        image: 'nginx:alpine'
        ports: {
          web: {
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
        value: password
        encoding: 'base64'
      }
      apikey: {
        value: apiKey
      }
    }
  }
}
