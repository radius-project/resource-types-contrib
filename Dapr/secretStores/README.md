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

- **Default mode.** If the resource does not set `componentType`, the Recipe deploys a `secretstores.kubernetes` component. The component reads Kubernetes secrets in the namespace of the application. This mode is the same as the legacy `local-dev` Recipe.
- **Bring-your-own mode.** If the resource sets `componentType`, the Recipe deploys the component with `componentType`, `version`, and `metadata` from the resource. This mode replaces `resourceProvisioning: 'manual'` in the legacy type.

The Dapr control plane must be installed on the cluster. The Dapr component name is the resource name.

## Recipe Input Properties

| Property | Type | Description |
| --- | --- | --- |
| `context.resource.name` | string | The name of the Dapr component. |
| `context.resource.properties.componentType` | string | The Dapr component type. Defaults to `secretstores.kubernetes`. |
| `context.resource.properties.version` | string | The Dapr component version. Defaults to `v1`. |
| `context.resource.properties.metadata` | object | Map of component metadata names to `value` or `secretKeyRef`. A `secretKeyRef` reads a Kubernetes secret. |
| `context.resource.properties.scopes` | array | Dapr app IDs that can load the component. The Recipe writes this list to the root `scopes` field of the component. If the list is empty or not set, every Dapr app in the namespace can load the component. |
| `context.resource.properties.allowedSecrets` | array | Names of the Kubernetes secrets that the Dapr apps can read. Applies only to `secretstores.kubernetes`. The Recipe fails if you set it with another component type. |

## Recipe Parameters

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `daprServiceAccountName` | string | `default` | The Kubernetes ServiceAccount of the Dapr apps that read secrets. The Recipe binds the secret-read Role to this ServiceAccount. |

## Recipe Output Properties

| Property | Type | Description |
| --- | --- | --- |
| `componentName` | string | The name of the Dapr component. |
| `version` | string | The Dapr component version. |

When `allowedSecrets` is set, the Recipe also creates a Role and a RoleBinding. The `resources` output includes them, so Radius deletes them with the resource.

## Consumer Access

A connection from a container to this resource does not limit which Dapr apps can use the component. Set `scopes` to the Dapr app IDs of the intended consumers. The Dapr app ID is `extensions.daprSidecar.appId` on the container. If `appId` is not set, the app ID is the container resource name. It is not the application name.

The Recipe does not set `scopes` from connections, because the Recipe context does not include the connected containers. If `scopes` is not set, the component is open to all Dapr apps in the namespace. This is the same as the legacy behavior.

## Secret Read Access

The Dapr sidecar reads Kubernetes secrets with the ServiceAccount of its Pod. The Dapr Helm chart gives the `default` ServiceAccount read access to secrets only in the `default` namespace. In other namespaces, the sidecar cannot read secrets until you give access.

Set `allowedSecrets` to the names of the secrets that the consumers can read. The Recipe then creates:

- A Role with `get` on only the secrets in `allowedSecrets`.
- A RoleBinding from the Role to the `daprServiceAccountName` ServiceAccount in the namespace of the environment.

Kubernetes denies reads of all other secrets. If `allowedSecrets` is not set, the Recipe does not give access. Do not give a namespace-wide secret read Role to the ServiceAccount.

Limits:

- The Kubernetes Container Recipes in this repository use the `default` ServiceAccount. Every Pod in the namespace that uses this ServiceAccount can read the allowed secrets. This includes reads through the Kubernetes API and through the built-in `kubernetes` Dapr secret store. `scopes` does not limit the built-in store. To limit reads to one workload, run that workload with its own ServiceAccount and set `daprServiceAccountName` to that ServiceAccount.
- For other component types, such as Azure Key Vault, control access in the secret store. `allowedSecrets` does not apply.

## Migrate from Applications.Dapr/secretStores

| Legacy property | New property |
| --- | --- |
| `resourceProvisioning: 'manual'` | Set `componentType`. |
| `resourceProvisioning: 'recipe'` | Do not set `componentType`. |
| `type` | `componentType`. The new name prevents a conflict with the `type` of the resource in connection environment variables. |
| `recipe` | Not used. Platform engineers register Recipes in the Environment. |
| `metadata`, `version`, `componentName` | No change. |
| Not available | `scopes`. Limits the Dapr apps that can load the component. |
| Not available | `allowedSecrets`. Gives read access to the named Kubernetes secrets only. |
