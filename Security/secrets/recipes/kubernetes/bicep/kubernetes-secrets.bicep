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
// Kubernetes Secret variables
//////////////////////////////////////////

// If secretKind is not set, set to 'generic'
var secretKind = context.resource.properties.?kind ?? 'generic'
var secretData = context.resource.properties.data

// Validate required fields for secret kinds
var missingFields = secretKind == 'certificate-pem' && (!contains(secretData, 'tls.crt') || !contains(secretData, 'tls.key')) 
  ? 'certificate-pem secrets must contain keys `tls.crt` and `tls.key`'
  : secretKind == 'basicAuthentication' && (!contains(secretData, 'username') || !contains(secretData, 'password'))
  ? 'basicAuthentication secrets must contain keys `username` and `password`'
  : secretKind == 'azureWorkloadIdentity' && (!contains(secretData, 'clientId') || !contains(secretData, 'tenantId'))
  ? 'azureWorkloadIdentity secrets must contain keys `clientId` and `tenantId`'
  : secretKind == 'awsIRSA' && !contains(secretData, 'roleARN')
  ? 'awsIRSA secrets must contain key `roleARN`'
  : ''

// Extract values from secretData formatted as {key: {value: "...", encoding: "..."}} 
// to flat format {key: "..."} for Kubernetes
var base64Data = reduce(items(secretData), {}, (acc, item) => 
  (contains(item.value, 'encoding') && item.value.encoding == 'base64') ? union(acc, {'${item.key}': item.value.value}) : acc
)
var stringData = reduce(items(secretData), {}, (acc, item) => 
  (!contains(item.value, 'encoding') || item.value.encoding != 'base64') ? union(acc, {'${item.key}': item.value.value}) : acc
)

// Determine secret type based on kind
var secretType = secretKind == 'certificate-pem' ? 'kubernetes.io/tls' : (secretKind == 'basicAuthentication' ? 'kubernetes.io/basic-auth' : 'Opaque')

//////////////////////////////////////////
// Kubernetes Secret resource
//////////////////////////////////////////

resource secret 'core/Secret@v1' = {
  metadata: {
    name: resourceName
    namespace: namespace
    labels: labels
  }
  type: secretType
  data: base64Data
  stringData: stringData
}

//////////////////////////////////////////
// Output Radius result 
//////////////////////////////////////////

output result object = {
  resources: [
    '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/core/Secret/${resourceName}'
  ]
}
