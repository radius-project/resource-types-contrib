mock_provider "kubernetes" {}
mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "fixture-generated-password" }
  }
}

variables {
  context = {
    application = null
    environment = null
    runtime     = { kubernetes = { namespace = "rabbitmq-fixture" } }
    resource = {
      id         = "/planes/radius/local/resourceGroups/test/providers/Radius.Messaging/rabbitMQ/broker"
      name       = "broker"
      type       = "Radius.Messaging/rabbitMQ"
      properties = {}
    }
  }
}

run "generated_password" {
  command = apply
  assert {
    condition     = output.result.secrets.password == "fixture-generated-password" && kubernetes_secret_v1.credentials[0].data.password == output.result.secrets.password
    error_message = "Return the generated password through managed secrets and store the same value in Kubernetes."
  }
  assert {
    condition     = length(output.result.resources) == 4 && contains(output.result.resources, "/planes/kubernetes/local/namespaces/rabbitmq-fixture/providers/core/Secret/${kubernetes_secret_v1.credentials[0].metadata[0].name}")
    error_message = "Track all four recipe-owned Kubernetes objects for cleanup."
  }
  assert {
    condition     = output.result.values.host == "${kubernetes_service_v1.rabbitmq.metadata[0].name}.rabbitmq-fixture.svc.cluster.local" && output.result.values.port == 5672 && output.result.values.username == "radius"
    error_message = "Return Service DNS, AMQP port, and default username."
  }
  assert {
    condition     = jsondecode(kubernetes_config_map_v1.broker.data["definitions.json"]).queues[0].name == "jobs" && jsondecode(kubernetes_config_map_v1.broker.data["definitions.json"]).users[0].password_hash == ""
    error_message = "Pre-provision the default queue without placing a password or hash in the ConfigMap."
  }
  assert {
    condition     = kubernetes_deployment_v1.rabbitmq.spec[0].template[0].metadata[0].annotations["radapp.io/definitions-hash"] == sha256(kubernetes_config_map_v1.broker.data["definitions.json"])
    error_message = "Restart the broker when its imported definitions change."
  }
  assert {
    condition     = kubernetes_deployment_v1.rabbitmq.spec[0].template[0].spec[0].init_container[0].env[0].value_from[0].secret_key_ref[0].name == kubernetes_secret_v1.credentials[0].metadata[0].name
    error_message = "Read credentials through secretKeyRef, not a literal environment value."
  }
  assert {
    condition     = kubernetes_deployment_v1.rabbitmq.spec[0].strategy[0].type == "Recreate" && tostring(kubernetes_deployment_v1.rabbitmq.spec[0].replicas) == "1" && kubernetes_deployment_v1.rabbitmq.spec[0].template[0].spec[0].container[0].readiness_probe[0].exec[0].command == tolist(["rabbitmq-diagnostics", "-q", "check_running"])
    error_message = "Run one broker and wait for application startup before routing clients."
  }
}

run "unchanged_redeployment" {
  command = plan
  assert {
    condition     = random_password.broker[0].result == run.generated_password.result.secrets.password
    error_message = "Keep the generated password on unchanged redeployment."
  }
}

run "supplied_password_and_quoted_names" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = {
          password = "/planes/radius/local/resourceGroups/test/providers/Radius.Security/secrets/existing"
          username = "user\"\\\n$(HOSTNAME)"
          queue    = "queue\"\\\n$(HOSTNAME)"
        }
      })
    })
  }
  assert {
    condition     = length(random_password.broker) == 0 && length(kubernetes_secret_v1.credentials) == 0 && length(output.result.secrets) == 0 && length(output.result.resources) == 3
    error_message = "Do not create, expose, or claim ownership of a supplied credential Secret."
  }
  assert {
    condition     = kubernetes_deployment_v1.rabbitmq.spec[0].template[0].spec[0].init_container[0].env[0].value_from[0].secret_key_ref[0].name == "existing"
    error_message = "Resolve the supplied Radius Secret ID to its Kubernetes name."
  }
  assert {
    condition     = jsondecode(kubernetes_config_map_v1.broker.data["definitions.json"]).users[0].name == var.context.resource.properties.username && jsondecode(kubernetes_config_map_v1.broker.data["definitions.json"]).queues[0].name == var.context.resource.properties.queue
    error_message = "JSON escaping must preserve user input, including quotes, backslashes, newlines, and dollars."
  }
}

run "null_optional_properties" {
  command = plan
  variables {
    context = merge(var.context, {
      resource = merge(var.context.resource, {
        properties = { username = null, queue = null, password = null }
      })
    })
  }
  assert {
    condition     = local.username == "radius" && local.queue == "jobs" && !local.supplied_password
    error_message = "Explicit nulls must use the same defaults as omitted optional properties."
  }
}
