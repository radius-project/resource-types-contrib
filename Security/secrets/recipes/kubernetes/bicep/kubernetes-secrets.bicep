extension kubernetes with {
  namespace: context.runtime.kubernetes.namespace
  kubeConfig: ''
} as kubernetes

param context object

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
var secretName = length(missingFields) > 0 ? missingFields : context.resource.name
    
resource secret 'core/Secret@v1' = {
  metadata: {
    name: secretName
    namespace: context.runtime.kubernetes.namespace
    labels: {
      resource: context.resource.name
      app: context.application == null ? '' : context.application.name
    }
  }
  type: secretType
  data: base64Data
  stringData: stringData
}

output result object = {
  resources: [
    '/planes/kubernetes/local/namespaces/${context.runtime.kubernetes.namespace}/providers/core/Secret/${secretName}'
  ]
}
