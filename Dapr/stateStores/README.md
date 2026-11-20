# Radius.Dapr/stateStores

## Overview

The **Radius.Dapr/stateStores** Resource Type deploys a [Dapr state store](https://docs.dapr.io/developing-applications/building-blocks/state-management/) component. It replaces the legacy `Applications.Dapr/stateStores` type. Applications that use the Dapr sidecar on a `Radius.Compute/containers` resource use the component to save and get state.

Developer documentation is in the Resource Type definition YAML file. Use the `rad resource-type show Radius.Dapr/stateStores` command to see it.

## Recipes

| Platform | IaC language | Recipe name | Stage |
| --- | --- | --- | --- |
| Kubernetes | Bicep | [`kubernetes-dapr-statestores.bicep`](recipes/kubernetes/bicep/kubernetes-dapr-statestores.bicep) | Alpha |
| Kubernetes | Terraform | [`main.tf`](recipes/kubernetes/terraform/main.tf) | Alpha |

The Kubernetes Recipes have two modes:

- **Default mode.** If the resource does not set `componentType`, the Recipe deploys a single-replica, non-persistent Redis `Deployment` and `Service`. It then deploys a `state.redis` Dapr component that uses the Redis instance. This mode is the same as the legacy `local-dev` Recipe. Use it for development and test only.
- **Bring-your-own mode.** If the resource sets `componentType`, the Recipe deploys only the Dapr component. It uses `componentType`, `version`, `metadata`, and `auth` from the resource. The platform engineer or the developer must supply all the metadata that the component type needs. This mode replaces `resourceProvisioning: 'manual'` in the legacy type.

The Dapr control plane must be installed on the cluster. The Dapr component name is the resource name.

## Recipe Input Properties

| Property | Type | Description |
| --- | --- | --- |
| `context.resource.name` | string | The name of the Dapr component. |
| `context.resource.properties.componentType` | string | The Dapr component type. If not set, the Recipe uses the default mode. |
| `context.resource.properties.version` | string | The Dapr component version. Defaults to `v1`. |
| `context.resource.properties.metadata` | object | Map of component metadata names to `value` or `secretKeyRef`. In the default mode, these entries override the default entries. |
| `context.resource.properties.scopes` | array | Nonempty, unique Dapr app IDs that can load the component. If omitted, use `daprAllowedAppIds`. |
| `context.resource.properties.auth.secretStore` | string | The Dapr secret store that resolves `secretKeyRef` values. |

## Recipe Parameters

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `daprAllowedAppIds` | array | `[]` | Platform allowlist and fallback when resource `scopes` is omitted. Resource scopes cannot extend a nonempty allowlist. |
| `actorStateStore` | bool | `false` | Sets the default Redis state store as the Dapr actor state store. Applies only in the default mode. |
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

The Recipe does not infer consumers from connections. Set `daprAllowedAppIds` in the platform Recipe parameters, or set resource `scopes`. If both are set, resource scopes must be a subset of the nonempty platform list. The Recipe rejects a broader list rather than dropping IDs. An empty platform list means no platform limit, not public access; the resource must then set scopes. An explicit empty resource list is rejected even when a platform list exists.

Each list must contain unique IDs of 1 to 63 lowercase letters, digits, or hyphens, with a letter or digit at each end. The Recipe writes the effective list at the Component root. Existing resources that omit scopes need an access list before redeployment. `application` stays optional and is not a Dapr app ID.

Scopes select app IDs; they do not authenticate workloads or restrict direct backend access. The platform must prevent untrusted workloads from reusing approved IDs and control backend network access and credentials.

Metadata entries must set exactly one of `value` or `secretKeyRef`. An empty plain value is valid; secret references need nonblank `name` and `key`. The Recipe rejects unknown resource, metadata-entry, and auth fields. It accepts the inherited `connections` and `codeReference` properties and Radius-owned `recipe` and `status` context fields. Schema limits validate list and string shapes; Recipe checks enforce the exclusive metadata choice and unknown-field rules because the Radius Bicep schema compiler does not support `additionalProperties: false`.

## Ownership and Updates

The Recipe does not install or upgrade Dapr. Component names and Redis names stay stable for unchanged input. Labels describe resources; they do not prove ownership. These Recipes cannot check the full owner resource ID before an update. Do not deploy onto a Component owned by another deployment. Runtime collision rejection and update enforcement remain review gaps.

Default Redis is temporary and has no retained volume. A restart, deletion, or switch to custom mode can lose its data. For data that must be retained, use an external durable backend. Before a backend change, export or back up its data, create a separate target and Component with a new resource name, restore the data, verify reads and writes, switch consumer connections and secret references, and keep the old backend until rollback is no longer needed.

Custom mode reports only the Component in `result.resources`; it does not report external services. This limits the cleanup list but is not proof of runtime deletion safety. Verify ownership, update, and cleanup behavior before production use. Do not use Pack removal as data cleanup.

## Migrate from Applications.Dapr/stateStores

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
