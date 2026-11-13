mock_provider "kubernetes" {}

variables {
  context = {
    application = null
    environment = null
    runtime     = { kubernetes = { namespace = "kafka-test" } }
    resource = {
      id         = "/planes/radius/local/resourceGroups/test/providers/Radius.Messaging/kafka/broker"
      name       = "broker"
      type       = "Radius.Messaging/kafka"
      properties = {}
    }
  }
}

run "defaults" {
  command = plan

  assert {
    condition = (
      local.broker_environment.RADIUS_KAFKA_TOPIC == "events" &&
      local.broker_environment.KAFKA_ADVERTISED_LISTENERS == "PLAINTEXT://broker.kafka-test.svc.cluster.local:9092" &&
      output.result.values.host == "broker.kafka-test.svc.cluster.local" &&
      output.result.secrets.connectionString == "broker.kafka-test.svc.cluster.local:9092"
    )
    error_message = "Use native Kafka bootstrap addresses and the default topic, not Event Hubs settings."
  }
  assert {
    condition = (
      kubernetes_deployment_v1.kafka.spec[0].replicas == "1" &&
      kubernetes_deployment_v1.kafka.spec[0].strategy[0].type == "Recreate" &&
      kubernetes_deployment_v1.kafka.spec[0].template[0].spec[0].volume[0].persistent_volume_claim[0].claim_name == "broker-data" &&
      kubernetes_persistent_volume_claim_v1.data.spec[0].resources[0].requests.storage == "1Gi" &&
      !kubernetes_persistent_volume_claim_v1.data.wait_until_bound &&
      kubernetes_service_v1.kafka.spec[0].publish_not_ready_addresses
    )
    error_message = "Retain data across single-broker updates and allow storage scheduling and pre-readiness topic creation."
  }
  assert {
    condition = (
      length(output.result.resources) == 3 &&
      contains(output.result.resources, "/planes/kubernetes/local/namespaces/kafka-test/providers/core/PersistentVolumeClaim/broker-data") &&
      contains(output.result.resources, "/planes/kubernetes/local/namespaces/kafka-test/providers/core/Service/broker") &&
      contains(output.result.resources, "/planes/kubernetes/local/namespaces/kafka-test/providers/apps/Deployment/broker")
    )
    error_message = "Track every created resource, including the PVC, for Radius cleanup."
  }
  assert {
    condition = (
      kubernetes_deployment_v1.kafka.spec[0].template[0].spec[0].container[0].lifecycle[0].post_start[0].exec[0].command[2] == file("${path.module}/create-topic.sh") &&
      strcontains(kubernetes_deployment_v1.kafka.spec[0].template[0].spec[0].container[0].readiness_probe[0].exec[0].command[2], "--describe --topic")
    )
    error_message = "Create the requested topic at startup and check it before marking the Pod ready."
  }
}

run "custom_topic" {
  command = plan
  variables {
    context = {
      runtime = { kubernetes = { namespace = "other" } }
      resource = {
        id         = "/planes/radius/local/resourceGroups/test/providers/Radius.Messaging/kafka/custom"
        name       = "custom"
        type       = "Radius.Messaging/kafka"
        properties = { topic = "order.events-1" }
      }
    }
  }
  assert {
    condition = (
      local.broker_environment.RADIUS_KAFKA_TOPIC == "order.events-1" &&
      local.broker_environment.KAFKA_ADVERTISED_LISTENERS == "PLAINTEXT://custom.other.svc.cluster.local:9092" &&
      local.labels["radapp.io/application"] == ""
    )
    error_message = "Honor the requested topic and namespace when optional application context is absent."
  }
}

run "null_topic" {
  command = plan
  variables {
    context = {
      runtime = { kubernetes = { namespace = "other" } }
      resource = {
        id         = "/planes/radius/local/resourceGroups/test/providers/Radius.Messaging/kafka/broker"
        name       = "broker"
        type       = "Radius.Messaging/kafka"
        properties = { topic = null }
      }
    }
  }
  assert {
    condition     = local.broker_environment.RADIUS_KAFKA_TOPIC == "events"
    error_message = "A null optional topic must use the same default as the Bicep recipe."
  }
}
