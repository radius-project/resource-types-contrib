mock_provider "kubernetes" {}

variables {
  context = {
    resource = {
      name = "postgresql"
      id   = "/planes/radius/local/resourcegroups/test/providers/Radius.Data/postgreSqlDatabases/postgresql"
      type = "Radius.Data/postgreSqlDatabases"
      properties = {
        username = "testadmin"
        password = "test-only-password"
        database = "appdb"
      }
    }
    application = { name = "testapp" }
    environment = { name = "testenv" }
    runtime     = { kubernetes = { namespace = "test" } }
  }
}

run "omitted_policy" {
  command = plan

  assert {
    condition = (
      local.tls_policy == "required" &&
      local.tls_secret_name == "postgresql-tls" &&
      strcontains(kubernetes_config_map.transport.data["pg_hba-required.conf"], "hostnossl all all 0.0.0.0/0 reject") &&
      strcontains(kubernetes_config_map.transport.data["pg_hba-required.conf"], "hostnossl all all ::/0 reject") &&
      strcontains(kubernetes_config_map.transport.data["pg_hba-required.conf"], "hostssl all all ::/0 scram-sha-256")
    )
    error_message = "Omitted tls must reject plaintext for both IP families and allow authenticated TLS."
  }

  assert {
    condition = (
      contains(kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].args, "ssl=on") &&
      contains(kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].args, "hba_file=/transport/pg_hba-required.conf") &&
      contains(kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].args, "password_encryption=scram-sha-256") &&
      kubernetes_deployment.postgresql.spec[0].strategy[0].type == "Recreate" &&
      strcontains(kubernetes_deployment.postgresql.spec[0].template[0].spec[0].init_container[0].command[2], "chmod 600 /tls/server.key") &&
      length(kubernetes_deployment.postgresql.spec[0].template[0].spec[0].volume) == 3
    )
    error_message = "The server must enable TLS and use protected startup certificate copies and explicit HBA rules."
  }

  assert {
    condition = (
      keys(output.result) == ["resources", "values"] &&
      keys(output.result.values) == ["database", "host", "port"] &&
      length(output.result.resources) == 4 &&
      output.result.values.database == "appdb" &&
      output.result.values.port == 5432
    )
    error_message = "Preserve cleanup IDs and connection values without returning credentials or certificate material."
  }
}

run "explicit_required" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = merge(var.context.resource.properties, { tls = "required" })
      })
    })
  }
  assert {
    condition     = local.tls_policy == "required" && contains(kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].args, "hba_file=/transport/pg_hba-required.conf")
    error_message = "Explicit required must reject plaintext."
  }
}

run "optional_policy" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = merge(var.context.resource.properties, { tls = "optional" })
      })
    })
  }
  assert {
    condition = (
      contains(kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].args, "ssl=on") &&
      contains(kubernetes_deployment.postgresql.spec[0].template[0].spec[0].container[0].args, "hba_file=/transport/pg_hba-optional.conf") &&
      strcontains(kubernetes_config_map.transport.data["pg_hba-optional.conf"], "hostnossl all all 0.0.0.0/0 scram-sha-256") &&
      strcontains(kubernetes_config_map.transport.data["pg_hba-optional.conf"], "hostnossl all all ::/0 scram-sha-256") &&
      kubernetes_deployment.postgresql.spec[0].template[0].metadata[0].annotations["radapp.io-postgresql-tls-policy"] == "optional"
    )
    error_message = "Optional must keep TLS enabled, require passwords for plaintext, and update the pod policy."
  }
}

run "operator_certificate" {
  command = plan
  variables {
    postgresqlTlsSecretName          = "operator-tls"
    postgresqlTlsCertificateRevision = "2"
  }
  assert {
    condition = (
      local.tls_secret_name == "operator-tls" &&
      kubernetes_deployment.postgresql.spec[0].template[0].metadata[0].annotations["radapp.io-postgresql-tls-revision"] == "2" &&
      alltrue([for id in output.result.resources : !strcontains(id, "operator-tls")])
    )
    error_message = "Operator certificate selection must trigger revision rollouts without taking ownership of the Secret."
  }
}

run "invalid_policy" {
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

run "null_policy" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = merge(var.context.resource.properties, { tls = null })
      })
    })
  }
  assert {
    condition     = local.tls_policy == "required"
    error_message = "Null tls must use the same safe default as omission."
  }
}

run "empty_policy" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = merge(var.context.resource.properties, { tls = "" })
      })
    })
  }
  expect_failures = [var.context]
}
