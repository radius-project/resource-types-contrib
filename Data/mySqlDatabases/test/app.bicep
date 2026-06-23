extension radius

@description('The Radius environment ID')
param environment string

@secure()
param password string

resource myapp 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'myapp'
  location: 'global'
  properties: {
    environment: environment
  }
}

resource dbSecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'mysqlsecret'
  properties: {
    environment: environment
    application: myapp.id
    data: {
      USERNAME: {
        value: 'admin'
      }
      PASSWORD: {
        value: password
      }
    }
  }
}

// TODO: Re-enable the container consumer once an Azure recipe for
// Radius.Compute/containers is merged. The shared test app is used by
// every platform, but the Azure recipe pack currently has no container
// recipe, so deploying this resource fails on the Azure validation job.
// resource mycontainer 'Radius.Compute/containers@2025-08-01-preview' = {
//   name: 'mycontainer'
//   properties: {
//     environment: environment
//     application: myapp.id
//     containers: {
//       demo: {
//         image: 'ghcr.io/radius-project/samples/demo:latest'
//         ports: {
//           web: {
//             containerPort: 3000
//           }
//         }
//       }
//     }
//     connections: {
//       mysql: {
//         source: mysql.id
//       }
//     }
//   }
// }

resource mysql 'Radius.Data/mySqlDatabases@2025-08-01-preview' = {
  name: 'mysql'
  properties: {
    environment: environment
    application: myapp.id
    secretName: dbSecret.name
  }
}
