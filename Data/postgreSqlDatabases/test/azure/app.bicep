extension radius
extension postgreSqlDatabases

param environment string
param applicationName string
@secure()
param password string
param tlsPolicy string = 'default'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: { environment: environment }
}

resource database 'postgreSqlDatabases:Radius.Data/postgreSqlDatabases@2025-08-01-preview' = {
  name: applicationName
  properties: union({
    environment: environment
    application: app.id
    username: 'radadmin'
    password: password
    database: 'appdb'
    size: 'S'
  }, tlsPolicy == 'default' ? {} : { tls: tlsPolicy })
}
