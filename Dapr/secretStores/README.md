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

## Recipe Output Properties

| Property | Type | Description |
| --- | --- | --- |
| `componentName` | string | The name of the Dapr component. |
| `version` | string | The Dapr component version. |

## Consumer Access

A connection from a container to this resource does not limit which Dapr apps can use the component. Set `scopes` to the Dapr app IDs of the intended consumers. The Dapr app ID is `extensions.daprSidecar.appId` on the container. If `appId` is not set, the app ID is the container resource name. It is not the application name.

The Recipe does not set `scopes` from connections, because the Recipe context does not include the connected containers. If `scopes` is not set, the component is open to all Dapr apps in the namespace. This is the same as the legacy behavior.

## Secret Read Access

The Dapr sidecar reads Kubernetes secrets with the ServiceAccount of its Pod. The Dapr Helm chart gives the `default` ServiceAccount read access to secrets only in the `default` namespace. In other namespaces, the sidecar cannot read secrets until you give access.

The Recipe does not give this access. Radius runs Recipes with an identity that cannot create or delete Kubernetes Roles. Before you deploy an application that reads secrets, create a Role with `get` on only the secrets that the consumers can read. Then bind it to the ServiceAccount of the consumer Pods. The Kubernetes Container Recipes in this repository use the `default` ServiceAccount. Replace `<namespace>` with the namespace of the environment:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dapr-secret-reader
  namespace: <namespace>
rules:
  - apiGroups: ['']
    resources: ['secrets']
    resourceNames: ['backend-api-key']
    verbs: ['get']
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dapr-secret-reader
  namespace: <namespace>
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: dapr-secret-reader
subjects:
  - kind: ServiceAccount
    name: default
    namespace: <namespace>
```

Kubernetes denies reads of all other secrets. Do not give a namespace-wide secret read Role to the ServiceAccount. The automated test creates the same Role for its allowed secret, and then makes sure that a read of a different secret fails.

Limits:

- Every Pod in the namespace that uses the `default` ServiceAccount can read the allowed secrets. This includes reads through the Kubernetes API and through the built-in `kubernetes` Dapr secret store. `scopes` does not limit the built-in store. The Kubernetes Container Recipes in this repository do not support a ServiceAccount for each workload.
- For other component types, such as Azure Key Vault, control access in the secret store.

## Migrate from Applications.Dapr/secretStores

| Legacy property | New property |
| --- | --- |
| `resourceProvisioning: 'manual'` | Set `componentType`. |
| `resourceProvisioning: 'recipe'` | Do not set `componentType`. |
| `type` | `componentType`. The new name prevents a conflict with the `type` of the resource in connection environment variables. |
| `recipe` | Not used. Platform engineers register Recipes in the Environment. |
| `metadata`, `version`, `componentName` | No change. |
| Not available | `scopes`. Limits the Dapr apps that can load the component. |
