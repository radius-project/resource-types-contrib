@description('Azure supports required or optional TLS, not disabled. Validated before deploying the AVM, regardless of server configuration overrides.')
@allowed([
  'required'
  'optional'
])
#disable-next-line no-unused-params // This parameter is a deployment-time contract guard, independent of operator overrides.
param tlsPolicy string

@description('PostgreSQL server name, forwarded to the pinned AVM.')
param name string
@description('Administrator username, forwarded unchanged.')
param administratorLogin string
@description('Administrator password, forwarded securely.')
@secure()
param administratorLoginPassword string
@description('Authentication settings, forwarded unchanged.')
param authConfig object
@description('Server SKU, forwarded unchanged.')
param skuName string
@description('Server tier, forwarded unchanged.')
@allowed(['GeneralPurpose', 'Burstable', 'MemoryOptimized'])
param tier string
@description('Database definitions, forwarded unchanged.')
param databases array
@description('PostgreSQL version, forwarded unchanged.')
@allowed(['11', '12', '13', '14', '15', '16', '17', '18'])
param version string
@description('Availability zone, forwarded unchanged.')
@allowed([-1, 1, 2, 3])
param availabilityZone int
@description('High availability configuration, forwarded unchanged.')
@allowed(['Disabled', 'SameZone', 'ZoneRedundant'])
param highAvailability string
@description('Geo-redundant backup setting, forwarded unchanged.')
@allowed(['Disabled', 'Enabled'])
param geoRedundantBackup string
@description('Storage size in GiB, forwarded unchanged.')
param storageSizeGB int
@description('Public network access setting, forwarded unchanged.')
@allowed(['Disabled', 'Enabled'])
param publicNetworkAccess string
@description('Firewall rules, forwarded unchanged.')
param firewallRules array
@description('Threat protection setting, forwarded unchanged.')
param enableAdvancedThreatProtection bool
@description('AVM telemetry setting, forwarded unchanged.')
param enableTelemetry bool
@description('Resource lock configuration, forwarded unchanged.')
param lock object
@description('Server settings, including operator transport overrides, forwarded unchanged.')
param configurations array

module server 'br/public:avm/res/db-for-postgre-sql/flexible-server:0.15.2' = {
  name: 'postgresql-${uniqueString(name)}'
  params: {
    name: name
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    authConfig: authConfig
    skuName: skuName
    tier: tier
    databases: databases
    version: version
    availabilityZone: availabilityZone
    highAvailability: highAvailability
    geoRedundantBackup: geoRedundantBackup
    storageSizeGB: storageSizeGB
    publicNetworkAccess: publicNetworkAccess
    firewallRules: firewallRules
    enableAdvancedThreatProtection: enableAdvancedThreatProtection
    enableTelemetry: enableTelemetry
    lock: lock
    configurations: configurations
  }
}

// An unordered existing-resource read can race the module on first deployment.
resource deployedServer 'Microsoft.DBforPostgreSQL/flexibleServers@2025-06-01-preview' existing = {
  name: name
  dependsOn: [
    server
  ]
}

output fqdn string = deployedServer.properties.?fullyQualifiedDomainName!
