mock_provider "kubernetes" {}

variables {
  context = {
    application = { name = "testapp" }
    environment = { name = "testenv" }
    runtime     = { kubernetes = { namespace = "mysql-fixture" } }
    resource = {
      id   = "/planes/radius/local/resourceGroups/test/providers/Radius.Data/mySqlDatabases/mysql"
      name = "mysql"
      type = "Radius.Data/mySqlDatabases"
      properties = {
        username = "fixture"
        password = "fixture-only"
        port     = 6000
      }
    }
  }
}

run "defaults_and_contract" {
  command = plan

  assert {
    condition     = kubernetes_deployment_v1.mysql.spec[0].template[0].spec[0].container[0].image == "mysql:8.4" && kubernetes_deployment_v1.mysql.spec[0].template[0].spec[0].container[0].args == tolist(["--require-secure-transport=ON"])
    error_message = "Omitted properties must use MySQL 8.4 with required TLS and preserve the image entrypoint."
  }

  assert {
    condition     = kubernetes_deployment_v1.mysql.spec[0].template[0].spec[0].container[0].command == null
    error_message = "Do not replace the image entrypoint that initializes users and certificates."
  }

  assert {
    condition = nonsensitive(kubernetes_secret_v1.mysql.data) == tomap({
      USERNAME = "fixture"
      PASSWORD = "fixture-only"
      }) && alltrue([
      for env in kubernetes_deployment_v1.mysql.spec[0].template[0].spec[0].container[0].env :
      env.value == null && env.value_from[0].secret_key_ref[0].name == "mysql-credentials" &&
      env.value_from[0].secret_key_ref[0].key == (env.name == "MYSQL_USER" ? "USERNAME" : "PASSWORD")
      if contains(["MYSQL_USER", "MYSQL_PASSWORD"], env.name)
    ])
    error_message = "Store credentials in the Secret and reference its keys from the Pod."
  }

  assert {
    condition     = kubernetes_secret_v1.mysql.metadata[0].namespace == "mysql-fixture" && kubernetes_deployment_v1.mysql.metadata[0].namespace == "mysql-fixture" && kubernetes_service_v1.mysql.metadata[0].namespace == "mysql-fixture"
    error_message = "Every resource must use the environment's runtime namespace."
  }

  assert {
    condition     = kubernetes_deployment_v1.mysql.spec[0].selector[0].match_labels == kubernetes_service_v1.mysql.spec[0].selector && kubernetes_deployment_v1.mysql.spec[0].template[0].metadata[0].labels["radapp.io/resource"] == "mysql"
    error_message = "The Deployment and Service must select the same Pods."
  }

  assert {
    condition     = kubernetes_deployment_v1.mysql.spec[0].template[0].spec[0].container[0].port[0].container_port == 3306 && kubernetes_service_v1.mysql.spec[0].port[0].port == 3306 && output.result.values.port == 3306
    error_message = "Ignore an authored connection port; report the real MySQL server and Service port."
  }

  assert {
    condition = output.result.values == {
      host     = "mysql.mysql-fixture.svc.cluster.local"
      port     = 3306
      database = "mysql_db"
      } && output.result.resources == [
      "/planes/kubernetes/local/namespaces/mysql-fixture/providers/core/Secret/mysql-credentials",
      "/planes/kubernetes/local/namespaces/mysql-fixture/providers/core/Service/mysql",
      "/planes/kubernetes/local/namespaces/mysql-fixture/providers/apps/Deployment/mysql"
    ] && sort(keys(output.result)) == tolist(["resources", "values"])
    error_message = "Return the connection values and three cleanup IDs, without secrets or credentials."
  }
}

run "custom_properties" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = merge(var.context.resource.properties, {
          database = "appdb"
          version  = "5.7"
          tls      = "optional"
        })
      })
    })
  }
  assert {
    condition     = kubernetes_deployment_v1.mysql.spec[0].template[0].spec[0].container[0].image == "mysql:5.7" && kubernetes_deployment_v1.mysql.spec[0].template[0].spec[0].container[0].args == tolist(["--require-secure-transport=OFF"]) && output.result.values.database == "appdb"
    error_message = "Honor the requested version, database, and optional transport policy."
  }
  assert {
    condition     = one([for env in kubernetes_deployment_v1.mysql.spec[0].template[0].spec[0].container[0].env : env.value if env.name == "MYSQL_DATABASE"]) == "appdb"
    error_message = "The reported database must match the database initialized by MySQL."
  }
}

run "null_optional_properties" {
  command = plan
  variables {
    context = merge(var.context, {
      application = null
      environment = null
      resource = merge(var.context.resource, {
        properties = merge(var.context.resource.properties, { database = null, version = null, tls = null })
      })
    })
  }
  assert {
    condition     = kubernetes_deployment_v1.mysql.spec[0].template[0].spec[0].container[0].image == "mysql:8.4" && kubernetes_deployment_v1.mysql.spec[0].template[0].spec[0].container[0].args == tolist(["--require-secure-transport=ON"]) && output.result.values.database == "mysql_db"
    error_message = "Null optional properties must use the same defaults as omitted properties."
  }
  assert {
    condition     = kubernetes_secret_v1.mysql.metadata[0].labels["radapp.io/application"] == "" && kubernetes_secret_v1.mysql.metadata[0].labels["radapp.io/environment"] == ""
    error_message = "An absent application must not block an environment-scoped database."
  }
}

run "explicit_required_mysql_80" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = merge(var.context.resource.properties, { version = "8.0", tls = "required" })
      })
    })
  }
  assert {
    condition     = kubernetes_deployment_v1.mysql.spec[0].template[0].spec[0].container[0].image == "mysql:8.0" && kubernetes_deployment_v1.mysql.spec[0].template[0].spec[0].container[0].args == tolist(["--require-secure-transport=ON"])
    error_message = "Support MySQL 8.0 and explicit required TLS."
  }
}

run "invalid_version" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = merge(var.context.resource.properties, { version = "9.0" })
      })
    })
  }
  expect_failures = [var.context]
}

run "invalid_tls" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = merge(var.context.resource.properties, { tls = "disabled" })
      })
    })
  }
  expect_failures = [var.context]
}
