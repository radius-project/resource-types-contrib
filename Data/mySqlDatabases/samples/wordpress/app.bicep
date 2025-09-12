extension radius
extension radiusResources

@description('The Radius Application ID. Injected automatically by the rad CLI.')
param application string

@description('The env ID of your Radius Environment. Set automatically by the rad CLI.')
param environment string

@description('Tag to pull for the WordPress container image.')
param tag string = 'latest'

var port int = 80

resource frontend 'Applications.Core/containers@2023-10-01-preview' = {
  name: 'wordpress'
  properties: {
    application: application
    environment: environment
    container: {
      image: 'wordpress:${tag}'
      ports: {
        web: {
          containerPort: port
        }
      }
      env: {
        WORDPRESS_DB_HOST: {
          value: '${database.properties.host}:${database.properties.port}'
        }
        WORDPRESS_DB_USER: {
          value: database.properties.user
        }
        WORDPRESS_DB_PASSWORD: {
          value: database.properties.password
        }
        WORDPRESS_DB_NAME: {
          value: database.properties.database
        }
      }
    }
    connections: {
      database: {
        source: database.id
      }
    }
  }
}

resource database 'Radius.Data/mySqlDatabases@2023-10-01-preview' = {
  name: 'mysql'
  properties: {
    application: application
    environment: environment
  }
}
