extension radius
extension secrets

param environment string

@secure()
param password string

// Temporarily required https://github.com/radius-project/resource-types-contrib/issues/52
resource testapp 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'testapp'
  properties: {
    environment: environment
  }
}

//
// Basic test case
//
// Test script:
//
// environment=$(rad env show -o json | jq -r '.name')
// password=$(openssl rand -base64 16)
// rad deploy app.bicep -p password=$password
// [[ "$(kubectl get secret testsecret1 -n $environment-testapp -o jsonpath="{.data.username}" | base64 --decode)" == "admin" ]] && echo "Username matches" || { echo "Username mismatch"; exit 1; }
// [[ "$(kubectl get secret testsecret1 -n $environment-testapp -o jsonpath="{.data.password}" | base64 --decode)" == "$password" ]] && echo "Password matches" || { echo "Password mismatch"; exit 1; }
//
resource testsecret1 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'testsecret1'
  properties: {
    environment: environment
    application: testapp.id
    data: {
      username: {
        value: 'admin'
      }
      password: {
        value: password
      }
    }
  }
}
