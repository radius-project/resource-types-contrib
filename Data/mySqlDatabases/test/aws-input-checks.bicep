// Used by assert-aws-input-checks.sh to deploy the AWS MySQL Recipe with
// specific property values. The Environment has no AWS account.
extension radius

@description('The ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

param applicationName string
param database string
param username string

@secure()
param password string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

resource mysql 'Radius.Data/mySqlDatabases@2025-08-01-preview' = {
  // Radius resource IDs don't include the application, so use a name that
  // test/app.bicep doesn't.
  name: applicationName
  properties: {
    environment: environment
    application: app.id
    database: database
    username: username
    password: password
  }
}
