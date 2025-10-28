output "resource_ids" {
  description = "List of Kubernetes resource IDs created by this module"
  value = [
    "/planes/kubernetes/local/namespaces/${var.namespace}/providers/apps/Deployment/${var.name}",
    "/planes/kubernetes/local/namespaces/${var.namespace}/providers/core/Service/${var.name}"
  ]
}

output "metadata" {
  description = "Dapr component metadata for Redis state store"
  value = [
    {
      name  = "redisHost"
      value = "${var.name}.${var.namespace}.svc.cluster.local:${var.redis_port}"
    },
    {
      name  = "redisPassword"
      value = ""
    }
  ]
}
