# Radius.Compute/gateways

`Radius.Compute/gateways` defines the ingress gateway shape for application traffic.

## Kubernetes Contour HTTPProxy recipe

The Contour HTTPProxy recipe is a compatibility recipe for clusters using Contour. Contour `HTTPProxy` does not require a separate Kubernetes Gateway API `Gateway` resource, so this recipe records gateway values used by companion route recipes instead of creating a Gateway API resource.

The recipe outputs:

- `gatewayName`: Radius gateway resource name.
- `gatewayNamespace`: Kubernetes namespace for the Radius environment.

The companion `Radius.Compute/routes` Contour HTTPProxy recipe creates the `projectcontour.io/v1 HTTPProxy` resource that routes traffic to the target container service.

## Example

```bicep
extension radius
extension gateways

param environment string

resource gateway 'Radius.Compute/gateways@2025-08-01-preview' = {
  name: 'web'
  properties: {
    environment: environment
    gatewayClassName: 'contour'
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
