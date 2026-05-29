# Radius.Compute/gateways

`Radius.Compute/gateways` creates a Kubernetes Gateway API `Gateway` for application ingress. The Kubernetes nginx recipes target NGINX Gateway Fabric by creating or reusing the `nginx` `GatewayClass`.

## Kubernetes nginx recipe

The nginx recipe expects NGINX Gateway Fabric to be installed in the cluster. The default NGINX Gateway Fabric Helm installation creates the `nginx` GatewayClass, and this recipe creates a Gateway that references it.

The recipe outputs:

- `gatewayName`: Kubernetes Gateway name.
- `gatewayNamespace`: Kubernetes namespace containing the Gateway.
- `resources`: Radius resource IDs for the Gateway.

## Example

```bicep
extension radius
extension gateways

param environment string

resource gateway 'Radius.Compute/gateways@2025-08-01-preview' = {
  name: 'web'
  properties: {
    environment: environment
    gatewayClassName: 'nginx'
    listeners: [
      {
        name: 'http'
        protocol: 'HTTP'
        port: 80
        allowedRoutesFrom: 'All'
      }
    ]
  }
}
```
