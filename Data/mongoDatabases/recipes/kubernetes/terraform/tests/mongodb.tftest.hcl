mock_provider "kubernetes" {}

variables {
  context = {
    application = null
    environment = null
    runtime     = { kubernetes = { namespace = "mongo-test" } }
    resource = {
      id         = "/planes/radius/local/resourceGroups/test/providers/Radius.Data/mongoDatabases/mongo"
      name       = "mongo"
      type       = "Radius.Data/mongoDatabases"
      properties = {}
    }
  }
}

run "generated_credentials" {
  command = apply

  assert {
    condition     = length(random_password.mongo[0].result) == 32 && kubernetes_secret_v1.credentials.data.password == random_password.mongo[0].result
    error_message = "Generate a random password and store it in the Kubernetes Secret."
  }
  assert {
    condition     = tonumber(kubernetes_deployment_v1.mongo.spec[0].replicas) == 1 && kubernetes_deployment_v1.mongo.spec[0].strategy[0].type == "Recreate" && kubernetes_persistent_volume_claim_v1.data.wait_until_bound == false
    error_message = "Use one database process and allow delayed volume binding."
  }
  assert {
    condition     = kubernetes_deployment_v1.mongo.spec[0].template[0].spec[0].container[0].env[1].value_from[0].secret_key_ref[0].name == "mongo-mongodb-credentials" && kubernetes_deployment_v1.mongo.spec[0].template[0].spec[0].volume[0].persistent_volume_claim[0].claim_name == "mongo-mongodb-data"
    error_message = "Wire the password Secret and persistent data volume into the Pod."
  }
  assert {
    condition = output.result.values == {
      database = "mongo_db"
      endpoint = "mongodb://mongo-mongodb.mongo-test.svc.cluster.local:27017"
    } && startswith(output.result.secrets.connectionString, "mongodb://radius:") && endswith(output.result.secrets.connectionString, "/mongo_db?authSource=admin")
    error_message = "Return the schema's public properties and an authenticated connection string."
  }
  assert {
    condition = toset(output.result.resources) == toset([
      "/planes/kubernetes/local/namespaces/mongo-test/providers/core/Secret/mongo-mongodb-credentials",
      "/planes/kubernetes/local/namespaces/mongo-test/providers/core/PersistentVolumeClaim/mongo-mongodb-data",
      "/planes/kubernetes/local/namespaces/mongo-test/providers/apps/Deployment/mongo-mongodb",
      "/planes/kubernetes/local/namespaces/mongo-test/providers/core/Service/mongo-mongodb"
    ])
    error_message = "Track all four Kubernetes objects for Radius cleanup."
  }
  assert {
    condition     = kubernetes_deployment_v1.mongo.metadata[0].namespace == "mongo-test" && kubernetes_secret_v1.credentials.metadata[0].namespace == "mongo-test" && kubernetes_persistent_volume_claim_v1.data.metadata[0].namespace == "mongo-test" && kubernetes_service_v1.mongo.metadata[0].namespace == "mongo-test"
    error_message = "Use the context namespace for every object."
  }
}

run "redeployment" {
  command = apply

  assert {
    condition     = output.result.secrets.connectionString == run.generated_credentials.result.secrets.connectionString
    error_message = "An unchanged deployment must retain its generated password."
  }
}

run "explicit_password_and_database" {
  command = apply

  variables {
    mongoPassword = "fixture @:/?#[]%&+ password"
    context = {
      runtime = { kubernetes = { namespace = "other-namespace" } }
      resource = {
        id         = "/planes/radius/local/resourceGroups/test/providers/Radius.Data/mongoDatabases/orders"
        name       = "orders"
        type       = "Radius.Data/mongoDatabases"
        properties = { database = "orders-v2" }
      }
    }
  }

  assert {
    condition     = length(random_password.mongo) == 0 && kubernetes_secret_v1.credentials.data.password == var.mongoPassword
    error_message = "An operator password must replace, not supplement, generated credentials."
  }
  assert {
    condition     = output.result.secrets.connectionString == "mongodb://radius:fixture%20%40%3A%2F%3F%23%5B%5D%25%26%2B%20password@orders-mongodb.other-namespace.svc.cluster.local:27017/orders-v2?authSource=admin"
    error_message = "Encode URI delimiters and spaces without changing the actual password."
  }
}

run "reject_short_password" {
  command = plan
  variables {
    mongoPassword = "too-short"
  }
  expect_failures = [var.mongoPassword]
}
