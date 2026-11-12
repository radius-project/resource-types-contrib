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
    condition     = length(kubernetes_config_map.extensions) == 0 && kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].args == tolist(["postgres"])
    error_message = "Omitted properties must keep the original startup without extension scripts."
  }
}

run "extensions_and_settings" {
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
          tls        = "optional"
          serverSettings = {
            log_min_duration_statement = "1000"
          }
        }
      }
    }
  }
  assert {
    condition     = kubernetes_config_map.extensions[0].data["00-extensions.sql"] == "CREATE EXTENSION IF NOT EXISTS \"pg_trgm\";\nCREATE EXTENSION IF NOT EXISTS \"btree_gin\";"
    error_message = "The init directory must receive quoted extension statements."
  }
  assert {
    condition     = kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].args == tolist(["postgres", "-c", "log_min_duration_statement=1000"])
    error_message = "Settings must be separate arguments, not shell commands."
  }
  assert {
    condition     = kubernetes_deployment.postgresql.spec[0].template[0].spec[0].volume[0].config_map[0].name == kubernetes_config_map.extensions[0].metadata[0].name && kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].volume_mount[0].mount_path == "/docker-entrypoint-initdb.d"
    error_message = "Mount extension statements in the PostgreSQL first-initialization directory."
  }
  assert {
    condition     = contains(output.result.resources, "/planes/kubernetes/local/namespaces/test/providers/core/ConfigMap/postgresql-extensions")
    error_message = "Track the extension ConfigMap for Radius cleanup."
  }
}

run "protected_settings_and_null_extensions" {
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
          extensions = null
          serverSettings = {
            port             = "6000"
            PORT             = "6001"
            Port             = "6002"
            SSL              = "off"
            ssl              = "off"
            Ssl_Cert_File    = "/bypass.crt"
            SSL_KEY_FILE     = "/bypass.key"
            Hba_File         = "/bypass.conf"
            application_name = "literal $(POSTGRES_DB) $$ $$(POSTGRES_DB) $value; `not a command`"
            log_line_prefix  = "$$"
            search_path      = "$(POSTGRES_DB)"
          }
        }
      }
    }
  }
  assert {
    condition     = length(kubernetes_config_map.extensions) == 0
    error_message = "Null extensions must not create an init ConfigMap."
  }
  assert {
    condition = kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].args == tolist([
      "postgres", "-c", "application_name=literal $$(POSTGRES_DB) $$$$ $$$$(POSTGRES_DB) $$value; `not a command`",
      "-c", "log_line_prefix=$$$$", "-c", "search_path=$$(POSTGRES_DB)"
    ])
    error_message = "Protected settings must be filtered without regard to case; Pod arguments must escape dollars for kubelet."
  }
  assert {
    # Protect escaped dollars before expanding this fixture's known environment reference.
    condition = tolist([
      for arg in kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].args :
      replace(replace(replace(arg, "$$", "__ESCAPED_DOLLAR__"), "$(POSTGRES_DB)", "postgres_db"), "__ESCAPED_DOLLAR__", "$")
      ]) == tolist([
      "postgres", "-c", "application_name=literal $(POSTGRES_DB) $$ $$(POSTGRES_DB) $value; `not a command`",
      "-c", "log_line_prefix=$$", "-c", "search_path=$(POSTGRES_DB)"
    ])
    error_message = "After Kubernetes expansion, process arguments must contain the original setting values."
  }
  assert {
    condition     = kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].port[0].container_port == 5432 && kubernetes_service.postgres.spec[0].port[0].port == 5432 && output.result.values.port == 5432
    error_message = "The container, Service, and reported connection must all use port 5432."
  }
  assert {
    condition     = strcontains(kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].command[2], "postgres \"$@\" -c port=5432 -c ssl=on") && strcontains(kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].command[2], "-c hba_file=/tls-runtime/pg_hba.conf")
    error_message = "Owned TLS and port arguments must follow application settings."
  }
}

run "empty_extensions_and_settings" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = merge(var.context.resource.properties, { extensions = [], serverSettings = {} })
      })
    })
  }
  assert {
    condition     = length(kubernetes_config_map.extensions) == 0 && kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].args == tolist(["postgres"])
    error_message = "Empty properties must keep the default startup."
  }
}
