# Radius.Dapr/configurationStores

## Overview

The **Radius.Dapr/configurationStores** Resource Type deploys a [Dapr configuration store](https://docs.dapr.io/developing-applications/building-blocks/configuration/) component. It replaces the legacy `Applications.Dapr/configurationStores` type. Applications that use the Dapr sidecar on a `Radius.Compute/containers` resource use the component to read configuration items and subscribe to changes.

Developer documentation is in the Resource Type definition YAML file. Use the `rad resource-type show Radius.Dapr/configurationStores` command to see it.

## Recipes

| Platform | IaC language | Recipe name | Stage |
| --- | --- | --- | --- |
| Kubernetes | Bicep | [`kubernetes-dapr-configurationstores.bicep`](recipes/kubernetes/bicep/kubernetes-dapr-configurationstores.bicep) | Alpha |
| Kubernetes | Terraform | [`main.tf`](recipes/kubernetes/terraform/main.tf) | Alpha |

The Kubernetes Recipes have two modes:

- **Default mode.** If the resource does not set `componentType`, the Recipe deploys a single-replica, non-persistent Redis `Deployment` and `Service`. It then deploys a `configuration.redis` Dapr component that uses the Redis instance. This mode is the same as the legacy `local-dev` Recipe. Use it for development and test only.
- **Bring-your-own mode.** If the resource sets `componentType`, the Recipe deploys only the Dapr component. It uses `componentType`, `version`, `metadata`, and `auth` from the resource. The platform engineer or the developer must supply all the metadata that the component type needs. This mode replaces `resourceProvisioning: 'manual'` in the legacy type.

The Dapr control plane must be installed on the cluster. The Dapr component name is the resource name.

## Recipe Input Properties

| Property | Type | Description |
| --- | --- | --- |
| `context.resource.name` | string | The name of the Dapr component. |
| `context.resource.properties.componentType` | string | The Dapr component type. If not set, the Recipe uses the default mode. |
| `context.resource.properties.version` | string | The Dapr component version. Defaults to `v1`. |
| `context.resource.properties.metadata` | object | Map of component metadata names to `value` or `secretKeyRef`. In the default mode, these entries override the default entries. |
| `context.resource.properties.scopes` | array | Dapr app IDs that can load the component. The Recipe writes this list to the root `scopes` field of the component. If the list is empty or not set, every Dapr app in the namespace can load the component. |
| `context.resource.properties.auth.secretStore` | string | The Dapr secret store that resolves `secretKeyRef` values. |

## Recipe Parameters

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `redisImageTag` | string | `7-alpine` | Tag of the `redis` container image. Applies only in the default mode. |
| `redisMemoryRequest` | string | `128Mi` | Memory request of the Redis container. Applies only in the default mode. |
| `redisMemoryLimit` | string | `1024Mi` | Memory limit of the Redis container. Applies only in the default mode. |

## Recipe Output Properties

| Property | Type | Description |
| --- | --- | --- |
| `componentName` | string | The name of the Dapr component. |
| `version` | string | The Dapr component version. |

The Recipe does not return `componentType`. Radius writes output values back to the resource. If the Recipe returned the default type, a later update could switch the resource out of the default mode and delete the default Redis instance.

## Consumer Access

A connection from a container to this resource does not limit which Dapr apps can use the component. Set `scopes` to the Dapr app IDs of the intended consumers. The Dapr app ID is `extensions.daprSidecar.appId` on the container. If `appId` is not set, the app ID is the container resource name. It is not the application name.

The Recipe does not set `scopes` from connections, because the Recipe context does not include the connected containers. If `scopes` is not set, the component is open to all Dapr apps in the namespace. This is the same as the legacy behavior.

## Migrate from Applications.Dapr/configurationStores

| Legacy property | New property |
| --- | --- |
| `resourceProvisioning: 'manual'` | Set `componentType`. The Recipe then deploys only the component. |
| `resourceProvisioning: 'recipe'` | Do not set `componentType`. |
| `type` | `componentType`. The new name prevents a conflict with the `type` of the resource in connection environment variables. |
| `recipe` | Not used. Platform engineers register Recipes in the Environment. |
| `resources` | Not used. |
| `metadata`, `version`, `auth`, `componentName` | No change. |
| Not available | `scopes`. Limits the Dapr apps that can load the component. |

Do not put secret material in a `metadata` `value`. Use `secretKeyRef` with `auth.secretStore`. Use a `Radius.Dapr/secretStores` resource to deploy the secret store.
