extension radius
extension containers

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
resource noConnectionsContainer 'containers:Radius.Compute/containers@2025-08-01-preview' = {
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
// Predictable service-to-service DNS coverage.
//
// A single-container resource publishes its Kubernetes Service DNS name as the
// read-only `host` output property. Peers address it by referencing
// `<peer>.properties.host` instead of hardcoding a Service name. `dnsServer`
// (resource name `dns-server`) exposes port 80; `dnsClient` injects
// `dnsServer.properties.host` into an init container that blocks until it can
// reach the server at that host. If the recipe does not populate `host`, the
// reference is empty, the init container never succeeds, the client pod never
// becomes ready, and this test deployment fails.
// ---------------------------------------------------------------------------
resource dnsServer 'containers:Radius.Compute/containers@2025-08-01-preview' = {
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

resource dnsClient 'containers:Radius.Compute/containers@2025-08-01-preview' = {
  name: 'dns-client'
  properties: {
    environment: environment
    application: app.id
    containers: {
      // Blocks until the server resolves by its published `host` output. Retries
      // for up to ~120s so the server has time to come up in the same deployment.
      waitForServer: {
        initContainer: true
        image: 'busybox:latest'
        command: ['sh', '-c']
        env: {
          SERVER_HOST: {
            value: dnsServer.properties.host
          }
        }
        args: [
          'echo "Resolving peer by host alias..."; for i in $(seq 1 60); do if wget -q -T 2 -O /dev/null "http://$SERVER_HOST:80"; then echo "Reached $SERVER_HOST:80 via host alias"; exit 0; fi; echo "attempt $i: $SERVER_HOST not reachable yet"; sleep 2; done; echo "FAILED: could not reach $SERVER_HOST:80 via host alias"; exit 1'
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

// ---------------------------------------------------------------------------
// Multi-container DNS coverage.
//
// A resource with two port-exposing containers publishes both Kubernetes Service
// DNS names in the read-only `hosts` map, keyed by container name. `multiClient`
// injects `multiServer.properties.hosts.alpha` and `.beta` into an init container
// that blocks until BOTH resolve. If the recipe does not populate every entry of
// `hosts`, one reference is empty, the init container never succeeds, and this test
// deployment fails — so the deploy gates on `hosts` being fully populated.
// ---------------------------------------------------------------------------
resource multiServer 'containers:Radius.Compute/containers@2025-08-01-preview' = {
  name: 'multi-server'
  properties: {
    environment: environment
    application: app.id
    containers: {
      alpha: {
        image: 'nginx:alpine'
        ports: {
          web: {
            containerPort: 80
            protocol: 'TCP'
          }
        }
      }
      beta: {
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

resource multiClient 'containers:Radius.Compute/containers@2025-08-01-preview' = {
  name: 'multi-client'
  properties: {
    environment: environment
    application: app.id
    containers: {
      // Blocks until both peers resolve by their published `hosts` entries.
      waitForBoth: {
        initContainer: true
        image: 'busybox:latest'
        command: ['sh', '-c']
        env: {
          ALPHA_HOST: {
            value: multiServer.properties.hosts.alpha
          }
          BETA_HOST: {
            value: multiServer.properties.hosts.beta
          }
        }
        args: [
          'echo "Resolving peers by hosts aliases..."; for i in $(seq 1 60); do if wget -q -T 2 -O /dev/null "http://$ALPHA_HOST:80" && wget -q -T 2 -O /dev/null "http://$BETA_HOST:80"; then echo "Reached both $ALPHA_HOST and $BETA_HOST via hosts aliases"; exit 0; fi; echo "attempt $i: peers not both reachable yet"; sleep 2; done; echo "FAILED: could not reach both peers via hosts aliases"; exit 1'
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
