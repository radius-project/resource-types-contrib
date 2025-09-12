output "mongodb_service_name" {
  value = kubernetes_service.mongodb.metadata[0].name
}

output "mongodb_credentials_secret" {
  value = kubernetes_secret.mongodb_credentials.metadata[0].name
}
