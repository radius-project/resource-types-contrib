@description('Authoritative resource and Azure context injected by Radius.')
param context object

@description('Literal AVM server configurations. An exact require_secure_transport entry overrides required/optional, but never permits disabled.')
param postgreSqlServerConfigurations array = []

var properties = context.resource.properties
var requestedTls = properties.?tls ?? 'required'
// Guard a required AVM input, not the override-dependent configuration branch.
var serverName = contains(['required', 'optional'], requestedTls)
  ? 'pgsql-${context.azure.resourceNameHash}'
  : fail('Azure PostgreSQL does not support this tls policy. Use required or optional; disabled is Kubernetes-only.')
var operatorSetsTransport = !empty(filter(postgreSqlServerConfigurations, config => config.?name == 'require_secure_transport'))
var size = properties.?size ?? 'S'

module server 'br:mcr.microsoft.com/bicep/avm/res/db-for-postgre-sql/flexible-server:0.15.2' = {
  name: 'postgresql'
  params: {
    name: serverName
    administratorLogin: properties.username
    administratorLoginPassword: properties.password
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
    }
    skuName: size == 'S' ? 'Standard_B1ms' : 'Standard_D2ds_v5'
    tier: size == 'S' ? 'Burstable' : 'GeneralPurpose'
    databases: [
      { name: properties.?database ?? 'postgres_db' }
    ]
    version: '16'
    availabilityZone: -1
    highAvailability: 'Disabled'
    geoRedundantBackup: 'Disabled'
    storageSizeGB: 32
    publicNetworkAccess: 'Enabled'
    firewallRules: [
      {
        name: 'allow-all'
        startIpAddress: '0.0.0.0'
        endIpAddress: '255.255.255.255'
      }
    ]
    enableAdvancedThreatProtection: false
    enableTelemetry: false
    lock: { kind: 'None' }
    configurations: concat(postgreSqlServerConfigurations, operatorSetsTransport ? [] : [
      {
        name: 'require_secure_transport'
        source: 'user-override'
        value: requestedTls == 'optional' ? 'OFF' : 'ON'
      }
    ])
  }
}

output result object = {
  // Preserve the exact ARM ID accepted by the Bicep driver; do not add a plane prefix.
  resources: [server.outputs.resourceId]
  values: {
    host: server.outputs.?fqdn ?? fail('Azure PostgreSQL did not return its required host.')
  }
}
