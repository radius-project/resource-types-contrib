mock_provider "kubernetes" {}

variables {
  # Mock plans do not start SQL Server or accept terms for a live deployment.
  sqlServerAcceptEula = "Y"
  context = {
    application = null
    environment = null
    runtime     = { kubernetes = { namespace = "isolated-test" } }
    resource = {
      id   = "/planes/radius/local/resourceGroups/test/providers/Radius.Data/sqlServerDatabases/sqlserver"
      name = "sqlserver"
      type = "Radius.Data/sqlServerDatabases"
      properties = {
        database = "custom]db'$(not-expanded)"
        username = "radadmin"
        password = "Fixture-only'$(not-expanded)42!"
        port     = 9999
      }
    }
  }
}

run "database_login_and_persistence" {
  command = plan
  assert {
    condition     = kubernetes_deployment_v1.server.spec[0].template[0].spec[0].container[0].command[2] == replace(file("bootstrap.sh"), "$", "$$")
    error_message = "Embed the complete shared bootstrap and protect literal dollars from kubelet."
  }
  assert {
    condition     = kubernetes_deployment_v1.server.spec[0].strategy[0].type == "Recreate" && tonumber(kubernetes_deployment_v1.server.spec[0].replicas) == 1 && kubernetes_persistent_volume_claim_v1.data.spec[0].resources[0].requests.storage == "8Gi"
    error_message = "Use persistent storage and a single writer during updates."
  }
  assert {
    condition     = kubernetes_deployment_v1.server.spec[0].template[0].spec[0].node_selector["kubernetes.io/arch"] == "amd64" && tonumber(kubernetes_deployment_v1.server.spec[0].template[0].spec[0].security_context[0].fs_group) == 10001
    error_message = "Schedule on supported nodes with writable non-root storage."
  }
  assert {
    condition     = output.result.values.port == 1433 && output.result.values.database == var.context.resource.properties.database && output.result.values.host == "sqlserver.isolated-test.svc.cluster.local"
    error_message = "Return the actual SQL port, database and namespace-qualified host."
  }
  assert {
    condition = toset(output.result.resources) == toset([
      "/planes/kubernetes/local/namespaces/isolated-test/providers/core/Secret/sqlserver-credentials",
      "/planes/kubernetes/local/namespaces/isolated-test/providers/core/PersistentVolumeClaim/sqlserver-data",
      "/planes/kubernetes/local/namespaces/isolated-test/providers/apps/Deployment/sqlserver",
      "/planes/kubernetes/local/namespaces/isolated-test/providers/core/Service/sqlserver"
    ])
    error_message = "Radius must track every object, including persistent storage."
  }
  assert {
    condition     = length(regexall("-U \"\\$RADIUS_USERNAME\" -d \"\\$RADIUS_DATABASE\"", kubernetes_deployment_v1.server.spec[0].template[0].spec[0].container[0].readiness_probe[0].exec[0].command[2])) == 1
    error_message = "Readiness must query the requested database as the requested login."
  }
  assert {
    condition     = nonsensitive(kubernetes_secret_v1.credentials.data.PASSWORD) == var.context.resource.properties.password && !can(output.result.secrets)
    error_message = "Keep the supplied password in a Secret, not a second output copy."
  }
}

run "reject_missing_consent" {
  command = plan
  variables {
    sqlServerAcceptEula = "N"
  }
  expect_failures = [var.sqlServerAcceptEula]
}

run "custom_storage" {
  command = plan
  variables {
    sqlServerStorageSize = "20Gi"
  }
  assert {
    condition     = kubernetes_persistent_volume_claim_v1.data.spec[0].resources[0].requests.storage == "20Gi"
    error_message = "The operator can select persistent capacity before deployment."
  }
}
