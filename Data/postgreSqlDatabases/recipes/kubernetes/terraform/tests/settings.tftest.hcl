mock_provider "kubernetes" {}

variables {
  context = {
    application = { name = "testapp" }
    environment = { name = "testenv" }
    runtime     = { kubernetes = { namespace = "test" } }
    resource = {
      id   = "/planes/radius/local/resourceGroups/test/providers/Radius.Data/postgreSqlDatabases/postgresql"
      name = "postgresql"
      type = "Radius.Data/postgreSqlDatabases"
      properties = {
        username = "fixture"
        password = "fixture-only"
      }
    }
  }
}

run "defaults" {
  command = plan
  assert {
    condition     = length(kubernetes_secret.init_scripts) == 0 && kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].args == tolist(["postgres"])
    error_message = "Omitted properties must keep the original startup command without init scripts."
  }
}

run "extensions_settings_and_seed" {
  command = plan
  variables {
    context = {
      application = { name = "testapp" }
      environment = { name = "testenv" }
      runtime     = { kubernetes = { namespace = "test" } }
      resource = {
        id   = "/planes/radius/local/resourceGroups/test/providers/Radius.Data/postgreSqlDatabases/postgresql"
        name = "postgresql"
        type = "Radius.Data/postgreSqlDatabases"
        properties = {
          username   = "fixture"
          password   = "fixture-only"
          extensions = ["pg_trgm", "btree_gin"]
          serverSettings = {
            log_min_duration_statement = "1000"
          }
          initSql = "CREATE SCHEMA IF NOT EXISTS app;"
        }
      }
    }
  }
  assert {
    condition     = kubernetes_secret.init_scripts[0].data["00-extensions.sql"] == "CREATE EXTENSION IF NOT EXISTS \"pg_trgm\";\nCREATE EXTENSION IF NOT EXISTS \"btree_gin\";"
    error_message = "Extension SQL must quote each extension name."
  }
  assert {
    condition     = kubernetes_secret.init_scripts[0].data["01-init.sql"] == "CREATE SCHEMA IF NOT EXISTS app;"
    error_message = "Seed SQL must run after extension creation."
  }
  assert {
    condition     = kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].args == tolist(["postgres", "-c", "log_min_duration_statement=1000"])
    error_message = "Server settings must be separate postgres arguments, not shell commands."
  }
  assert {
    condition     = kubernetes_deployment.postgresql.spec[0].template[0].spec[0].volume[0].secret[0].secret_name == kubernetes_secret.init_scripts[0].metadata[0].name
    error_message = "Init SQL must be mounted from the managed Secret."
  }
}
