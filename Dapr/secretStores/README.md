# Radius.Dapr/secretStores

## Overview

The **Radius.Dapr/secretStores** Resource Type deploys a [Dapr secret store](https://docs.dapr.io/developing-applications/building-blocks/secrets/) component. It replaces the legacy `Applications.Dapr/secretStores` type. Applications that use the Dapr sidecar on a `Radius.Compute/containers` resource use the component to read secrets. Other Dapr components use the component to resolve `secretKeyRef` metadata values.

Developer documentation is in the Resource Type definition YAML file. Use the `rad resource-type show Radius.Dapr/secretStores` command to see it.

## Recipes

| Platform | IaC language | Recipe name | Stage |
| --- | --- | --- | --- |
| Kubernetes | Bicep | [`kubernetes-dapr-secretstores.bicep`](recipes/kubernetes/bicep/kubernetes-dapr-secretstores.bicep) | Alpha |
| Kubernetes | Terraform | [`main.tf`](recipes/kubernetes/terraform/main.tf) | Alpha |

The Kubernetes Recipes deploy only a Dapr component. They do not deploy a backing secret store.

- **Default mode.** If the resource does not set `type`, the Recipe deploys a `secretstores.kubernetes` component. The component reads Kubernetes secrets in the namespace of the application. This mode is the same as the legacy `local-dev` Recipe.
- **Bring-your-own mode.** If the resource sets `type`, the Recipe deploys the component with `type`, `version`, and `metadata` from the resource. This mode replaces `resourceProvisioning: 'manual'` in the legacy type.

The Dapr control plane must be installed on the cluster. The Dapr component name is the resource name.

## Recipe Input Properties

| Property | Type | Description |
| --- | --- | --- |
| `context.resource.name` | string | The name of the Dapr component. |
| `context.resource.properties.type` | string | The Dapr component type. Defaults to `secretstores.kubernetes`. |
| `context.resource.properties.version` | string | The Dapr component version. Defaults to `v1`. |
| `context.resource.properties.metadata` | object | Map of component metadata names to `value` or `secretKeyRef`. A `secretKeyRef` reads a Kubernetes secret. |

## Recipe Output Properties

| Property | Type | Description |
| --- | --- | --- |
| `componentName` | string | The name of the Dapr component. |
| `type` | string | The Dapr component type. |
| `version` | string | The Dapr component version. |

## Migrate from Applications.Dapr/secretStores

| Legacy property | New property |
| --- | --- |
| `resourceProvisioning: 'manual'` | Set `type`. |
| `resourceProvisioning: 'recipe'` | Do not set `type`. |
| `recipe` | Not used. Platform engineers register Recipes in the Environment. |
| `metadata`, `type`, `version`, `componentName` | No change. |
