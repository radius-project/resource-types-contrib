terraform {
  required_version = ">= 1.5"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
  }
}

# ========================================
# Local Values - Basic Configuration
# ========================================
locals {
  resource_name    = var.context.resource.name
  namespace        = var.context.runtime.kubernetes.namespace
  application_name = var.context.application != null ? var.context.application.name : ""
  normalized_name  = lower(replace(replace(replace(local.resource_name, "_", "-"), ".", "-"), " ", "-"))

  # Extract resource properties
  resource_properties = try(var.context.resource.properties, {})
  containers          = try(local.resource_properties.containers, {})
  volumes             = try(local.resource_properties.volumes, {})
  restart_policy      = try(local.resource_properties.restartPolicy, null)

  # Connections - used for linked resources like persistent volumes
  connections = try(var.context.resource.connections, {})

  # Replica count - use from properties or default to 1
  replica_count = try(local.resource_properties.replicas, 1)

  # AutoScaling configuration
  autoscaling         = try(local.resource_properties.autoScaling, null)
  has_autoscaling     = local.autoscaling != null
  autoscaling_min     = local.has_autoscaling ? try(local.autoscaling.minReplicas, local.replica_count) : local.replica_count
  autoscaling_max     = local.has_autoscaling ? try(local.autoscaling.maxReplicas, 10) : 10
  autoscaling_metrics = local.has_autoscaling ? try(local.autoscaling.metrics, []) : []

  # Build labels
  labels = {
    resource                 = local.resource_name
    app                      = local.application_name
    "radapp.io/application"  = local.application_name
    "app.kubernetes.io/name" = local.normalized_name
  }
}

# ========================================
# Container Processing
# ========================================
locals {
  # Separate regular containers from init containers
  regular_containers = {
    for name, config in local.containers : name => config
    if try(config.initContainer, false) == false
  }

  init_containers = {
    for name, config in local.containers : name => config
    if try(config.initContainer, false) == true
  }

  # Build complete container specs for regular containers
  container_specs = {
    for name, config in local.regular_containers : name => {
      name        = name
      image       = config.image
      command     = try(config.command, null)
      args        = try(config.args, null)
      working_dir = try(config.workingDir, null)

      # Ports
      ports = [
        for port_name, port_config in try(config.ports, {}) : {
          name           = port_name
          container_port = port_config.containerPort
          protocol       = try(port_config.protocol, "TCP")
        }
      ]

      # Environment variables
      env = [
        for env_name, env_config in try(config.env, {}) : {
          name       = env_name
          value      = try(env_config.value, null)
          value_from = try(env_config.valueFrom, null)
        }
      ]

      # Volume mounts
      volume_mounts = [
        for vm in try(config.volumeMounts, []) : merge(
          {
            name       = vm.volumeName
            mount_path = vm.mountPath
          },
          try(vm.subPath, null) != null ? { sub_path = vm.subPath } : {},
          try(vm.readOnly, null) != null ? { read_only = vm.readOnly } : {},
          try(vm.readOnly, null) == null && try(local.volumes[vm.volumeName].persistentVolume.accessMode, "") != "" && lower(local.volumes[vm.volumeName].persistentVolume.accessMode) == "readonlymany" ? {
            read_only = true
          } : {}
        )
      ]

      # Resources - Transform memoryInMib to memory format
      resources = try(config.resources, null) != null ? {
        limits = try(config.resources.limits, null) != null ? {
          cpu    = try(config.resources.limits.cpu, null)
          memory = try(config.resources.limits.memoryInMib, null) != null ? "${config.resources.limits.memoryInMib}Mi" : null
        } : null
        requests = try(config.resources.requests, null) != null ? {
          cpu    = try(config.resources.requests.cpu, null)
          memory = try(config.resources.requests.memoryInMib, null) != null ? "${config.resources.requests.memoryInMib}Mi" : null
        } : null
      } : null

      # Probes
      liveness_probe  = try(config.livenessProbe, null)
      readiness_probe = try(config.readinessProbe, null)

      # Container-level restart policy
      restart_policy = try(config.restartPolicy, null)
    }
  }

  # Build init container specs
  init_container_specs = {
    for name, config in local.init_containers : name => {
      name        = name
      image       = config.image
      command     = try(config.command, null)
      args        = try(config.args, null)
      working_dir = try(config.workingDir, null)

      # Ports
      ports = [
        for port_name, port_config in try(config.ports, {}) : {
          name           = port_name
          container_port = port_config.containerPort
          protocol       = try(port_config.protocol, "TCP")
        }
      ]

      # Environment variables
      env = [
        for env_name, env_config in try(config.env, {}) : {
          name       = env_name
          value      = try(env_config.value, null)
          value_from = try(env_config.valueFrom, null)
        }
      ]

      # Volume mounts
      volume_mounts = [
        for vm in try(config.volumeMounts, []) : merge(
          {
            name       = vm.volumeName
            mount_path = vm.mountPath
          },
          try(vm.subPath, null) != null ? { sub_path = vm.subPath } : {},
          try(vm.readOnly, null) != null ? { read_only = vm.readOnly } : {},
          try(vm.readOnly, null) == null && try(local.volumes[vm.volumeName].persistentVolume.accessMode, "") != "" && lower(local.volumes[vm.volumeName].persistentVolume.accessMode) == "readonlymany" ? {
            read_only = true
          } : {}
        )
      ]

      # Resources - Transform memoryInMib to memory format
      resources = try(config.resources, null) != null ? {
        limits = try(config.resources.limits, null) != null ? {
          cpu    = try(config.resources.limits.cpu, null)
          memory = try(config.resources.limits.memoryInMib, null) != null ? "${config.resources.limits.memoryInMib}Mi" : null
        } : null
        requests = try(config.resources.requests, null) != null ? {
          cpu    = try(config.resources.requests.cpu, null)
          memory = try(config.resources.requests.memoryInMib, null) != null ? "${config.resources.requests.memoryInMib}Mi" : null
        } : null
      } : null
    }
  }
}

# ========================================
# Volume Processing
# ========================================
locals {
  volume_specs = [
    for vol_name, vol_config in local.volumes : {
      name = vol_name

      # Persistent Volume Claim
      persistent_volume_claim = try(vol_config.persistentVolume, null) != null ? (
        try(vol_config.persistentVolume.claimName, "") != "" ? {
          claim_name = vol_config.persistentVolume.claimName
          } : (
          try(local.connections[vol_name].status.computedValues.claimName, "") != "" ? {
            claim_name = local.connections[vol_name].status.computedValues.claimName
          } : null
        )
      ) : null

      # Secret
      secret = try(vol_config.secret, null) != null ? {
        secret_name = vol_config.secret.secretName
      } : null

      # EmptyDir
      empty_dir = try(vol_config.emptyDir, null) != null ? {
        medium = try(vol_config.emptyDir.medium, "")
      } : null
    }
  ]
}

# ========================================
# Service Configuration
# ========================================
locals {
  # Build services config - one service per container with ports
  services_config = {
    for name, spec in local.container_specs : name => {
      container_name = name
      ports          = spec.ports
    }
    if length(spec.ports) > 0
  }
}

# ========================================
# HPA Metrics Processing
# ========================================
locals {
  hpa_metrics = [
    for metric in local.autoscaling_metrics : {
      type = (metric.kind == "cpu" || metric.kind == "memory") ? "Resource" : "External"

      # Resource metrics (CPU, memory)
      resource = (metric.kind == "cpu" || metric.kind == "memory") ? {
        name = metric.kind
        target = {
          type                = try(metric.target.averageUtilization, null) != null ? "Utilization" : try(metric.target.averageValue, null) != null ? "AverageValue" : "Value"
          average_utilization = try(metric.target.averageUtilization, null)
          average_value       = try(metric.target.averageValue, null) != null ? tostring(metric.target.averageValue) : null
          value               = try(metric.target.value, null) != null ? tostring(metric.target.value) : null
        }
      } : null

      # External/Custom metrics
      external = try(metric.customMetric, null) != null ? {
        metric = {
          name = metric.customMetric
        }
        target = {
          type                = try(metric.target.averageUtilization, null) != null ? "Utilization" : try(metric.target.averageValue, null) != null ? "AverageValue" : "Value"
          average_utilization = try(metric.target.averageUtilization, null)
          average_value       = try(metric.target.averageValue, null) != null ? tostring(metric.target.averageValue) : null
          value               = try(metric.target.value, null) != null ? tostring(metric.target.value) : null
        }
      } : null
    }
  ]
}

# ========================================
# Kubernetes Deployment
# ========================================
resource "kubernetes_deployment" "deployment" {
  metadata {
    name      = local.normalized_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    replicas = local.replica_count

    selector {
      match_labels = {
        resource                 = local.resource_name
        "app.kubernetes.io/name" = local.normalized_name
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        # Restart policy at pod level
        restart_policy = local.restart_policy

        # Init containers
        dynamic "init_container" {
          for_each = local.init_container_specs

          content {
            name        = init_container.value.name
            image       = init_container.value.image
            command     = init_container.value.command
            args        = init_container.value.args
            working_dir = init_container.value.working_dir

            # Ports
            dynamic "port" {
              for_each = init_container.value.ports
              content {
                name           = port.value.name
                container_port = port.value.container_port
                protocol       = port.value.protocol
              }
            }

            # Environment variables
            dynamic "env" {
              for_each = [for e in init_container.value.env : e if e.value != null]
              content {
                name  = env.value.name
                value = env.value.value
              }
            }

            # Environment variables from valueFrom
            dynamic "env" {
              for_each = [for e in init_container.value.env : e if e.value_from != null]
              content {
                name = env.value.name

                dynamic "value_from" {
                  for_each = env.value.value_from != null ? [env.value.value_from] : []
                  content {
                    dynamic "secret_key_ref" {
                      for_each = try(value_from.value.secretKeyRef, null) != null ? [value_from.value.secretKeyRef] : []
                      content {
                        name = secret_key_ref.value.name
                        key  = secret_key_ref.value.key
                      }
                    }
                  }
                }
              }
            }

            # Volume mounts
            dynamic "volume_mount" {
              for_each = init_container.value.volume_mounts
              content {
                name       = volume_mount.value.name
                mount_path = volume_mount.value.mount_path
                sub_path   = try(volume_mount.value.sub_path, null)
                read_only  = try(volume_mount.value.read_only, null)
              }
            }

            # Resources
            dynamic "resources" {
              for_each = init_container.value.resources != null ? [init_container.value.resources] : []
              content {
                limits   = try(resources.value.limits, null)
                requests = try(resources.value.requests, null)
              }
            }
          }
        }

        # Regular containers
        dynamic "container" {
          for_each = local.container_specs

          content {
            name        = container.value.name
            image       = container.value.image
            command     = container.value.command
            args        = container.value.args
            working_dir = container.value.working_dir

            # Ports
            dynamic "port" {
              for_each = container.value.ports
              content {
                name           = port.value.name
                container_port = port.value.container_port
                protocol       = port.value.protocol
              }
            }

            # Environment variables with direct values
            dynamic "env" {
              for_each = [for e in container.value.env : e if e.value != null]
              content {
                name  = env.value.name
                value = env.value.value
              }
            }

            # Environment variables from valueFrom
            dynamic "env" {
              for_each = [for e in container.value.env : e if e.value_from != null]
              content {
                name = env.value.name

                dynamic "value_from" {
                  for_each = env.value.value_from != null ? [env.value.value_from] : []
                  content {
                    dynamic "secret_key_ref" {
                      for_each = try(value_from.value.secretKeyRef, null) != null ? [value_from.value.secretKeyRef] : []
                      content {
                        name = secret_key_ref.value.name
                        key  = secret_key_ref.value.key
                      }
                    }
                  }
                }
              }
            }

            # Volume mounts
            dynamic "volume_mount" {
              for_each = container.value.volume_mounts
              content {
                name       = volume_mount.value.name
                mount_path = volume_mount.value.mount_path
                sub_path   = try(volume_mount.value.sub_path, null)
                read_only  = try(volume_mount.value.read_only, null)
              }
            }

            # Resources
            dynamic "resources" {
              for_each = container.value.resources != null ? [container.value.resources] : []
              content {
                limits   = try(resources.value.limits, null)
                requests = try(resources.value.requests, null)
              }
            }

            # Liveness probe
            dynamic "liveness_probe" {
              for_each = container.value.liveness_probe != null ? [container.value.liveness_probe] : []
              content {
                initial_delay_seconds = try(liveness_probe.value.initialDelaySeconds, null)
                period_seconds        = try(liveness_probe.value.periodSeconds, null)
                timeout_seconds       = try(liveness_probe.value.timeoutSeconds, null)
                failure_threshold     = try(liveness_probe.value.failureThreshold, null)
                success_threshold     = try(liveness_probe.value.successThreshold, null)

                # Exec probe
                dynamic "exec" {
                  for_each = try(liveness_probe.value.exec, null) != null ? [liveness_probe.value.exec] : []
                  content {
                    command = exec.value.command
                  }
                }

                # HTTP GET probe
                dynamic "http_get" {
                  for_each = try(liveness_probe.value.httpGet, null) != null ? [liveness_probe.value.httpGet] : []
                  content {
                    port   = http_get.value.port
                    path   = try(http_get.value.path, null)
                    scheme = try(upper(http_get.value.scheme), "HTTP")

                    dynamic "http_header" {
                      for_each = try(http_get.value.httpHeaders, [])
                      content {
                        name  = http_header.value.name
                        value = http_header.value.value
                      }
                    }
                  }
                }

                # TCP socket probe
                dynamic "tcp_socket" {
                  for_each = try(liveness_probe.value.tcpSocket, null) != null ? [liveness_probe.value.tcpSocket] : []
                  content {
                    port = tcp_socket.value.port
                  }
                }
              }
            }

            # Readiness probe
            dynamic "readiness_probe" {
              for_each = container.value.readiness_probe != null ? [container.value.readiness_probe] : []
              content {
                initial_delay_seconds = try(readiness_probe.value.initialDelaySeconds, null)
                period_seconds        = try(readiness_probe.value.periodSeconds, null)
                timeout_seconds       = try(readiness_probe.value.timeoutSeconds, null)
                failure_threshold     = try(readiness_probe.value.failureThreshold, null)
                success_threshold     = try(readiness_probe.value.successThreshold, null)

                # Exec probe
                dynamic "exec" {
                  for_each = try(readiness_probe.value.exec, null) != null ? [readiness_probe.value.exec] : []
                  content {
                    command = exec.value.command
                  }
                }

                # HTTP GET probe
                dynamic "http_get" {
                  for_each = try(readiness_probe.value.httpGet, null) != null ? [readiness_probe.value.httpGet] : []
                  content {
                    port   = http_get.value.port
                    path   = try(http_get.value.path, null)
                    scheme = try(upper(http_get.value.scheme), "HTTP")

                    dynamic "http_header" {
                      for_each = try(http_get.value.httpHeaders, [])
                      content {
                        name  = http_header.value.name
                        value = http_header.value.value
                      }
                    }
                  }
                }

                # TCP socket probe
                dynamic "tcp_socket" {
                  for_each = try(readiness_probe.value.tcpSocket, null) != null ? [readiness_probe.value.tcpSocket] : []
                  content {
                    port = tcp_socket.value.port
                  }
                }
              }
            }
          }
        }

        # Volumes
        dynamic "volume" {
          for_each = local.volume_specs
          content {
            name = volume.value.name

            # Persistent Volume Claim
            dynamic "persistent_volume_claim" {
              for_each = volume.value.persistent_volume_claim != null ? [volume.value.persistent_volume_claim] : []
              content {
                claim_name = persistent_volume_claim.value.claim_name
              }
            }

            # Secret
            dynamic "secret" {
              for_each = volume.value.secret != null ? [volume.value.secret] : []
              content {
                secret_name = secret.value.secret_name
              }
            }

            # EmptyDir
            dynamic "empty_dir" {
              for_each = volume.value.empty_dir != null ? [volume.value.empty_dir] : []
              content {
                medium = empty_dir.value.medium
              }
            }
          }
        }
      }
    }
  }
}

# ========================================
# Kubernetes Services (one per container with ports)
# ========================================
resource "kubernetes_service" "services" {
  for_each = local.services_config

  metadata {
    name      = "${local.normalized_name}-${each.value.container_name}"
    namespace = local.namespace
    labels = merge(local.labels, {
      container = each.value.container_name
    })
  }

  spec {
    type = "ClusterIP"

    selector = {
      resource                 = local.resource_name
      "app.kubernetes.io/name" = local.normalized_name
    }

    dynamic "port" {
      for_each = each.value.ports
      content {
        name        = port.value.name
        port        = port.value.container_port
        target_port = port.value.container_port
        protocol    = port.value.protocol
      }
    }
  }
}

# ========================================
# Horizontal Pod Autoscaler
# ========================================
resource "kubernetes_horizontal_pod_autoscaler_v2" "hpa" {
  count = local.has_autoscaling ? 1 : 0

  metadata {
    name      = local.normalized_name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = local.normalized_name
    }

    min_replicas = local.autoscaling_min
    max_replicas = local.autoscaling_max

    dynamic "metric" {
      for_each = local.hpa_metrics
      content {
        type = metric.value.type

        # Resource metrics (CPU, memory)
        dynamic "resource" {
          for_each = metric.value.resource != null ? [metric.value.resource] : []
          content {
            name = resource.value.name
            target {
              type                = resource.value.target.type
              average_utilization = resource.value.target.average_utilization
              average_value       = resource.value.target.average_value
              value               = resource.value.target.value
            }
          }
        }

        # External/Custom metrics
        dynamic "external" {
          for_each = metric.value.external != null ? [metric.value.external] : []
          content {
            metric {
              name = external.value.metric.name
            }
            target {
              type                = external.value.target.type
              average_utilization = external.value.target.average_utilization
              average_value       = external.value.target.average_value
              value               = external.value.target.value
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_deployment.deployment]
}

# ========================================
# Outputs
# ========================================
output "result" {
  value = {
    resources = concat(
      ["/planes/kubernetes/local/namespaces/${local.namespace}/providers/apps/Deployment/${local.normalized_name}"],
      [for svc_name, svc_config in local.services_config : "/planes/kubernetes/local/namespaces/${local.namespace}/providers/core/Service/${local.normalized_name}-${svc_config.container_name}"],
      local.has_autoscaling ? ["/planes/kubernetes/local/namespaces/${local.namespace}/providers/autoscaling/HorizontalPodAutoscaler/${local.normalized_name}"] : []
    )
    values = merge(
      {
        deploymentName = local.normalized_name
        namespace      = local.namespace
      },
      length(local.services_config) > 0 ? {
        services = [
          for svc_name, svc_config in local.services_config : {
            name      = "${local.normalized_name}-${svc_config.container_name}"
            namespace = local.namespace
          }
        ]
      } : {}
    )
  }
}
