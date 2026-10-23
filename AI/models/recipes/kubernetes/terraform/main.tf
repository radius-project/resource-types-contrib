terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
  }
}

locals {
  resource_name    = var.context.resource.name
  application_name = var.context.application != null ? var.context.application.name : ""
  environment_name = var.context.environment != null ? var.context.environment.name : ""
  resource_group   = element(split("/", var.context.resource.id), 5)
  namespace        = var.context.runtime.kubernetes.namespace
  port             = 11434
  tag              = "0.34.4"

  # `model` is the name clients send in OpenAI API requests. Hosted OpenAI model
  # names such as the default `gpt-5-mini` have no open weights, so for any name
  # that starts with `gpt-` (except the open-weight `gpt-oss` family) the Recipe
  # pulls a small open-weight CPU model and serves it under the requested name.
  # Any other value is pulled as-is from the Ollama library, for example
  # `llama3.2:1b`.
  model_input          = try(var.context.resource.properties.model, null)
  model                = local.model_input != null ? local.model_input : "gpt-5-mini"
  default_model        = "qwen2.5:0.5b"
  serves_default_model = startswith(lower(local.model), "gpt-") && !startswith(lower(local.model), "gpt-oss")
  source_model         = local.serves_default_model ? local.default_model : local.model

  labels = {
    "radapp.io/resource"       = local.resource_name
    "radapp.io/application"    = local.application_name
    "radapp.io/environment"    = local.environment_name
    "radapp.io/resource-type"  = replace(var.context.resource.type, "/", "-")
    "radapp.io/resource-group" = local.resource_group
  }

  host = "${local.resource_name}.${local.namespace}.svc.cluster.local"

  # Starts the Ollama server, pulls the source model and, when it differs,
  # copies it to the requested model name so requests for `model` resolve. The
  # pull runs in the background so SIGTERM is forwarded to the server without
  # waiting for a download to finish. A pull that still fails after five
  # attempts stops the container with an error. The readiness probe passes only
  # after the model is available.
  start_script = <<-EOT
    set -u
    ollama serve &
    server=$!
    trap 'kill -TERM "$server" 2>/dev/null' TERM INT
    until ollama list >/dev/null 2>&1; do
      kill -0 "$server" 2>/dev/null || break
      sleep 1
    done
    ready=false
    for attempt in 1 2 3 4 5; do
      kill -0 "$server" 2>/dev/null || break
      ollama pull "$SOURCE_MODEL" &
      if wait $!; then
        if [ "$SOURCE_MODEL" = "$MODEL_NAME" ] || ollama cp "$SOURCE_MODEL" "$MODEL_NAME"; then
          ready=true
          break
        fi
      fi
      echo "Attempt $attempt to pull model $SOURCE_MODEL failed" >&2
      sleep 5
    done
    if [ "$ready" = true ]; then
      touch /tmp/model-ready
    elif kill -0 "$server" 2>/dev/null; then
      echo "Could not pull model $SOURCE_MODEL" >&2
      kill -TERM "$server" 2>/dev/null
      wait "$server"
      exit 1
    fi
    wait "$server"
    status=$?
    while kill -0 "$server" 2>/dev/null; do
      wait "$server"
      status=$?
    done
    exit "$status"
  EOT
}

# In-cluster Ollama Deployment. Serves the OpenAI-compatible API under /v1 on
# port 11434, with inference on the CPU. Ollama does not authenticate requests.
resource "kubernetes_deployment" "ollama" {
  # Like the Bicep Recipe, return without waiting for the Pod to become ready.
  # Pulling the image and the model can take several minutes; the readiness
  # probe keeps the Service without endpoints until the model is available.
  wait_for_rollout = false

  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    # Single-replica, non-persistent server: Recreate tears down the old Pod
    # before starting the new one on update, so two servers never pull and hold
    # the same model at once (default RollingUpdate would run both).
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "radapp.io/resource" = local.resource_name
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        container {
          name    = "ollama"
          image   = "ollama/ollama:${local.tag}"
          command = ["bash", "-c", local.start_script]

          port {
            container_port = local.port
          }

          env {
            name  = "SOURCE_MODEL"
            value = local.source_model
          }

          env {
            name  = "MODEL_NAME"
            value = local.model
          }

          readiness_probe {
            exec {
              command = ["bash", "-c", "test -f /tmp/model-ready"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          resources {
            requests = {
              memory = "1Gi"
            }
          }

          volume_mount {
            name       = "models"
            mount_path = "/root/.ollama"
          }
        }

        volume {
          name = "models"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "ollama" {
  metadata {
    name      = local.resource_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    type = "ClusterIP"

    selector = {
      "radapp.io/resource" = local.resource_name
    }

    port {
      port = local.port
    }
  }
}

output "result" {
  value = {
    resources = [
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${kubernetes_service.ollama.metadata[0].name}",
      "/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${kubernetes_deployment.ollama.metadata[0].name}"
    ]
    values = {
      # The OpenAI-compatible base URL. OpenAI client libraries append paths
      # such as /chat/completions to it.
      endpoint = "http://${local.host}:${local.port}/v1"
    }
    secrets = {
      # Ollama does not authenticate requests. OpenAI client libraries still
      # require a non-empty API key, so the Recipe returns the placeholder
      # `ollama`, which the server ignores. Radius materializes it into the
      # managed Radius.Security/secrets resource; it is never written onto the
      # resource.
      apiKey = "ollama"
    }
  }
  sensitive = true
}
