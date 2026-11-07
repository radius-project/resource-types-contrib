# Kubernetes Recipe for Radius.Messaging/rabbitMQ (Terraform)

## Recipe Description

This Terraform module ([`main.tf`](main.tf), [`var.tf`](var.tf)) runs a single RabbitMQ broker from the official `rabbitmq` image in the Environment's namespace. It creates the same objects as the Bicep Recipe in [`../bicep`](../bicep): a single-replica `Deployment`, a `ClusterIP` `Service`, a `ConfigMap` that enables the definitions import, and an init container that pre-provisions the user and the `queue`. When `password` is omitted, it also creates a Kubernetes `Secret` with a generated password and returns it as `secrets.password`.

See the [resource type README](../../../README.md) for the properties and outputs.

## Usage Instructions

The checked-in Kubernetes Recipe Pack registers only Bicep Recipes, so register this module in a Recipe Pack of your own with `kind: 'terraform'`. Set `source` to a Terraform module source that Radius can download, for example an HTTP URL of a zip of this directory, which is how the repository's CI tests it:

```bicep
'Radius.Messaging/rabbitMQ': {
  kind: 'terraform'
  source: '<module source>'
}
```

The module needs only the `context` variable, which Radius sets. It uses the `hashicorp/kubernetes` and `hashicorp/random` providers. The generated password is kept in the Terraform state, so it stays the same when the resource is deployed again.
