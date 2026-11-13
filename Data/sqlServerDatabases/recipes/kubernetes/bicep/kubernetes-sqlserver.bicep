extension kubernetes with {
  kubeConfig: ''
  namespace: context.runtime.kubernetes.namespace
} as kubernetes

@description('Radius Recipe context.')
param context object

@description('Set to Y only after the operator accepts the Microsoft SQL Server license terms. No default consent is supplied.')
@allowed(['Y'])
param sqlServerAcceptEula string

@description('Persistent volume size. The namespace must have a default StorageClass.')
param sqlServerStorageSize string = '8Gi'

var resourceName = context.resource.name
var namespace = context.runtime.kubernetes.namespace
var database = context.resource.properties.database
var labels = {
  'radapp.io/resource': resourceName
  'radapp.io/application': context.?application.?name ?? ''
  'radapp.io/environment': context.?environment.?name ?? ''
  'radapp.io/resource-type': replace(context.resource.type, '/', '-')
  'radapp.io/resource-group': split(context.resource.id, '/')[5]
}
var image = 'mcr.microsoft.com/mssql/server:2022-CU28-ubuntu-22.04'
// Both packages use the same bootstrap; Bicep embeds it at publish time.
var bootstrap = replace(loadTextContent('../terraform/bootstrap.sh'), '$', '$$')
var readiness = 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S tcp:127.0.0.1,1433 -U "$RADIUS_USERNAME" -d "$RADIUS_DATABASE" -C -x -b -l 3 -t 3 -Q "SELECT 1" >/dev/null 2>&1'

resource credentials 'core/Secret@v1' = {
  metadata: {
    name: '${resourceName}-credentials'
    namespace: namespace
    labels: labels
  }
  stringData: {
    USERNAME: context.resource.properties.username
    PASSWORD: context.resource.properties.password
  }
}

resource data 'core/PersistentVolumeClaim@v1' = {
  metadata: {
    name: '${resourceName}-data'
    namespace: namespace
    labels: labels
  }
  spec: {
    accessModes: ['ReadWriteOnce']
    resources: {
      requests: {
        storage: sqlServerStorageSize
      }
    }
  }
}

resource server 'apps/Deployment@v1' = {
  metadata: {
    name: resourceName
    namespace: namespace
    labels: labels
  }
  spec: {
    replicas: 1
    strategy: {
      type: 'Recreate'
    }
    selector: {
      matchLabels: {
        'radapp.io/resource': resourceName
      }
    }
    template: {
      metadata: {
        labels: labels
      }
      spec: {
        nodeSelector: {
          'kubernetes.io/os': 'linux'
          'kubernetes.io/arch': 'amd64'
        }
        securityContext: {
          fsGroup: 10001
          runAsUser: 10001
          runAsGroup: 10001
          runAsNonRoot: true
        }
        terminationGracePeriodSeconds: 60
        containers: [
          {
            name: 'sqlserver'
            image: image
            command: ['/bin/bash', '-ec', bootstrap]
            env: [
              { name: 'ACCEPT_EULA', value: sqlServerAcceptEula }
              { name: 'MSSQL_PID', value: 'Developer' }
              { name: 'MSSQL_TCP_PORT', value: '1433' }
              { name: 'MSSQL_MEMORY_LIMIT_MB', value: '2048' }
              { name: 'RADIUS_DATABASE', value: database }
              {
                name: 'RADIUS_USERNAME'
                valueFrom: {
                  secretKeyRef: { name: credentials.metadata.name, key: 'USERNAME' }
                }
              }
              {
                name: 'MSSQL_SA_PASSWORD'
                valueFrom: {
                  secretKeyRef: { name: credentials.metadata.name, key: 'PASSWORD' }
                }
              }
            ]
            ports: [{ name: 'sqlserver', containerPort: 1433 }]
            resources: {
              requests: { cpu: '2', memory: '2Gi' }
              limits: { memory: '3Gi' }
            }
            readinessProbe: {
              exec: { command: ['/bin/bash', '-ec', readiness] }
              timeoutSeconds: 10
              periodSeconds: 10
            }
            volumeMounts: [{ name: 'data', mountPath: '/var/opt/mssql' }]
          }
        ]
        volumes: [
          {
            name: 'data'
            persistentVolumeClaim: { claimName: data.metadata.name }
          }
        ]
      }
    }
  }
}

resource service 'core/Service@v1' = {
  metadata: {
    name: resourceName
    namespace: namespace
    labels: labels
  }
  spec: {
    type: 'ClusterIP'
    selector: { 'radapp.io/resource': resourceName }
    ports: [{ port: 1433, targetPort: 'sqlserver' }]
  }
}

output result object = {
  resources: [
    '/planes/kubernetes/local/namespaces/${namespace}/providers/core/Secret/${credentials.metadata.name}'
    '/planes/kubernetes/local/namespaces/${namespace}/providers/core/PersistentVolumeClaim/${data.metadata.name}'
    '/planes/kubernetes/local/namespaces/${namespace}/providers/apps/Deployment/${server.metadata.name}'
    '/planes/kubernetes/local/namespaces/${namespace}/providers/core/Service/${service.metadata.name}'
  ]
  values: {
    host: '${service.metadata.name}.${namespace}.svc.cluster.local'
    port: 1433
    database: database
  }
}
