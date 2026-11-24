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
| `context.resource.properties.scopes` | array | Nonempty, unique Dapr app IDs that can load the component. If omitted, use `daprAllowedAppIds`. |

## Recipe Parameters

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `daprAllowedAppIds` | array | `[]` | Platform allowlist and fallback when resource `scopes` is omitted. Resource scopes cannot extend a nonempty allowlist. |

## Recipe Output Properties

| Property | Type | Description |
| --- | --- | --- |
| `componentName` | string | The name of the Dapr component. |
| `version` | string | The Dapr component version. |

## Consumer Access

A connection from a container to this resource does not limit which Dapr apps can use the component. Set `scopes` to the Dapr app IDs of the intended consumers. The Dapr app ID is `extensions.daprSidecar.appId` on the container. If `appId` is not set, the app ID is the container resource name. It is not the application name.

The Recipe does not infer consumers from connections. Set `daprAllowedAppIds` in the platform Recipe parameters, or set resource `scopes`. If both are set, resource scopes must be a subset of the nonempty platform list. The Recipe rejects a broader list rather than dropping IDs. An empty platform list means no platform limit, not public access; the resource must then set scopes. An explicit empty resource list is rejected even when a platform list exists.

Each list must contain unique IDs of 1 to 63 lowercase letters, digits, or hyphens, with a letter or digit at each end. The Recipe writes the effective list at the Component root. Existing resources that omit scopes need an access list before redeployment. `application` stays optional and is not a Dapr app ID.

Metadata entries must set exactly one of `value` or `secretKeyRef`. An empty plain value is valid; secret references need nonblank `name` and `key`. The Recipe rejects unknown resource and metadata-entry fields, including `auth` on a secret store. It accepts the inherited `connections` and `codeReference` properties and Radius-owned `recipe` and `status` context fields. Schema limits validate list and string shapes; Recipe checks enforce the exclusive metadata choice and unknown-field rules because the Radius Bicep schema compiler does not support `additionalProperties: false`.

## Ownership and Updates

The Recipe does not install or upgrade Dapr. It reports only the Component in `result.resources`, not the Kubernetes secrets or an external secret store. This limits the cleanup list but is not proof of runtime deletion safety. Labels describe resources; they do not prove ownership. These Recipes cannot check the full owner resource ID before an update. Do not deploy onto a Component owned by another deployment. Runtime collision rejection, update enforcement, and cleanup safety remain review gaps.

Before a backend change, create a separate Component with a new resource name, copy or provision the needed secrets through the platform's secure process, verify permitted and denied reads, switch consumer connections and dependent `auth.secretStore` references, and keep the old store until rollback is no longer needed. Do not use Pack removal as secret cleanup.

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

- Every Pod that shares a ServiceAccount can read its allowed secrets through the Kubernetes API and the built-in `kubernetes` Dapr secret store. Component `scopes` does not limit those paths. Set the Container Recipe's `serviceAccountName` parameter to a workload-specific ServiceAccount and use secret-specific RBAC. Scopes alone do not prove workload identity or restrict direct backend access.
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
