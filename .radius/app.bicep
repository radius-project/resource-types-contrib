extension radius

@description('The ID of the Radius Environment to deploy into.')
param environment string

@description('The RabbitMQ broker password.')
@secure()
param password string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'resource-types-contrib'
  properties: {
    environment: environment
  }
}

resource rabbitmqSecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'rabbitmq-credentials'
  properties: {
    environment: environment
    application: app.id
    data: {
      password: {
        value: password
      }
    }
  }
}

resource queue 'Radius.Messaging/rabbitMQ@2025-08-01-preview' = {
  name: 'rabbitmq'
  properties: {
    environment: environment
    application: app.id
    queue: 'jobs'
    username: 'radius'
    password: rabbitmqSecret.id
  }
}
