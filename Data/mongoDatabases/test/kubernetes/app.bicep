extension radius

@description('The Radius Environment ID. Set automatically by the rad CLI.')
param environment string

@description('Application name. CI supplies a unique name for deployment and cleanup.')
param applicationName string = 'mongodb-kubernetes-test'

@description('Database resource name. The Bicep test setup creates its matching credential Secret.')
param mongoResourceName string = 'mongo'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: applicationName
  properties: {
    environment: environment
  }
}

resource mongo 'Radius.Data/mongoDatabases@2025-08-01-preview' = {
  name: mongoResourceName
  properties: {
    environment: environment
    application: app.id
    database: 'mongo_db'
  }
}

resource client 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'democontainer'
  properties: {
    environment: environment
    application: app.id
    containers: {
      demo: {
        image: 'mongo:8.0'
        command: [
          'sleep'
          'infinity'
        ]
        env: {
          MONGODB_CONNECTIONSTRING: {
            valueFrom: {
              secretKeyRef: {
                secretName: mongo.properties.secrets.name
                key: 'connectionString'
              }
            }
          }
        }
        readinessProbe: {
          exec: {
            command: [
              'mongosh'
              '--quiet'
              '--nodb'
              '--eval'
              '''
const connection = new Mongo(process.env.MONGODB_CONNECTIONSTRING);
const collection = connection.getDB("mongo_db").getCollection("radius_recipe_test");
collection.updateOne({_id: "connection"}, {$set: {value: "ok"}}, {upsert: true});
quit(collection.findOne({_id: "connection"}).value === "ok" ? 0 : 1);
'''
            ]
          }
          periodSeconds: 5
          timeoutSeconds: 10
          failureThreshold: 30
        }
      }
    }
    connections: {
      mongodb: {
        source: mongo.id
        disableDefaultEnvVars: true
      }
    }
  }
}
