extension kubernetes with {
  namespace: namespace
  kubeConfig: ''
} as kubernetes

//////////////////////////////////////////
// Common Radius variables
//////////////////////////////////////////

param context object

var resourceName       = context.resource.name
var namespace          = context.runtime.kubernetes.namespace
var resourceProperties = context.resource.properties ?? {}

// Extract last segment from environment path for labels
var environmentId     = resourceProperties.?environment ?? ''
var environmentParts  = environmentId != '' ? split(environmentId, '/') : []
var environmentLabel  = length(environmentParts) > 0
  ? environmentParts[length(environmentParts) - 1]
  : ''

// Extract resource group name
// Index 4 is the resource group name
var resourceGroupName = split(context.resource.id, '/')[4]

// Application name (safe)
var applicationName = context.application != null ? context.application.name : ''

// Common labels 
var labels = {
  'radapp.io/resource':       resourceName
  'radapp.io/application':    applicationName
  'radapp.io/environment':    environmentLabel
  'radapp.io/resource-type':  replace(context.resource.type, '/', '-')
  'radapp.io/resource-group': resourceGroupName
}

//////////////////////////////////////////
// PostgreSQL variables
//////////////////////////////////////////

@description('Memory limits for the PostgreSQL container')
var memory ={
  S: {
    memoryRequest: '512Mi'
  } 
  M: {
    memoryRequest: '1Gi'
  }
  L: {
    memoryRequest: '2Gi'
  }
} 

var port = 5432

// Get the secret reference. Should be only a single connected resource.
var radiusConnectionsMap = context.resource.?connections ?? {}
var radiusConnectionList = items(radiusConnectionsMap)
var radiusFirstConnection = length(radiusConnectionList) > 0 ? radiusConnectionList[0].value : null
var radiusSecretName = radiusFirstConnection != null ? (radiusFirstConnection.?name ?? null) : null


//////////////////////////////////////////
// PostgreSQL variables
//////////////////////////////////////////

resource postgresql 'apps/Deployment@v1' = {
  metadata: {
    name: resourceName
    namespace: namespace
    labels: labels
  }
  spec: {
    selector: {
      matchLabels: {
        app: 'postgres'
      }
    }
    template: {
      metadata: {
        labels: union(labels, {
          app: 'postgres'
        })
        }
      spec: {
        containers: [
          {
            // This container is the running postgresql instance.
            name: 'postgres'
            image: 'postgres:16-alpine'
            resources: {
              requests: {
                memory: memory[context.resource.properties.size].memoryRequest
              }
            }
            ports: [
              {
                containerPort: port 
              }
            ]
            env: [
              {
                name: 'POSTGRES_USER'
                valueFrom: {
                  secretKeyRef: {
                  name: radiusSecretName
                  key: 'username'
                  }
                }
              }
              {
                name: 'POSTGRES_PASSWORD'
                valueFrom: {
                  secretKeyRef: {
                    name: radiusSecretName
                    key: 'password'
                  }
                }
              }
              {
                name: 'POSTGRES_DB'
                value: 'postgres_db'
              }
            ]
          }
        ]
      }
    }
  }
}

resource svc 'core/Service@v1' = {
  metadata: {
    name: resourceName
    namespace: namespace
    labels: labels
  }
  spec: {
    type: 'ClusterIP'
    selector: {
      app: 'postgres'
    }
    ports: [
      {
        port: port 
      }
    ]
  }
}

//////////////////////////////////////////
// Output Radius result 
//////////////////////////////////////////

output result object = {
  resources: [
    '/planes/kubernetes/local/namespaces/${svc.metadata.namespace}/providers/core/Service/${svc.metadata.name}'
    '/planes/kubernetes/local/namespaces/${postgresql.metadata.namespace}/providers/apps/Deployment/${postgresql.metadata.name}'
  ]
  values: {
    host: '${svc.metadata.name}.${svc.metadata.namespace}.svc.cluster.local'
    port: port
    database: 'postgres_db'
  }
}
