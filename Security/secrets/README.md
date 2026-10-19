## Overview
The Radius.Security/secrets Resource Type stores sensitive data such as tokens, passwords, keys, and certificates. It is used by developers as part of their applications as well as by platform engineers to configure authentication for Radius to access Bicep Recipes stored in OCI registries and Terraform Recipes stored in Git repositories.

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Security/secrets`. 

## Recipes

A list of available Recipes for this Resource Type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Bicep | recipes/kubernetes/bicep/kubernetes-secrets.bicep | Alpha |
| Kubernetes | Terraform | recipes/kubernetes/terraform/main.tf | Alpha |
| Azure (ACI) | Bicep | recipes/azure/bicep/azure-keyvault-secrets.bicep | Alpha |


## Recipe Input Properties

Properties for the Secrets resource are provided to the recipe via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.resource.properties.kind` (string, optional): The kind of content of the Secret. This optional property allows the developer to specify what kind of data is stored in the Secret. When not specified, Recipes should assume `generic`. Recipes may store Secrets as key-value pairs or use secret store-specific features to store as other types. For example, certificates may be stored as Kubernetes secrets of type `tls`. 

- `context.resource.properties.data` (object, required): A map of secret names to objects containing values and optional encoding. Each key in the `data` object maps to an object with:
  - `value` (string, required): The secret value. This field is annotated with `x-radius-sensitive`, which means Radius will encrypt it before database storage and redact it during deployment.
  - `encoding` (string, optional): Content encoding of the value. Recipes should assume `string` unless `base64` is specified.

## Using Secrets with Containers

On Kubernetes, a Container can connect directly to a user-authored `Radius.Security/secrets` resource. The Container Recipes inject every data key through a Kubernetes `secretKeyRef` using the uppercased name `CONNECTION_<CONNECTION-NAME>_<SECRET-KEY>`. For example, a connection named `credentials` to a Secret containing `username` and `apiKey` creates `CONNECTION_CREDENTIALS_USERNAME` and `CONNECTION_CREDENTIALS_APIKEY` in every regular and init container. This intentionally differs from the previous `envFrom` behavior: the full generated name is now uppercase instead of preserving the Secret data key's casing.

Set `disableDefaultEnvVars: true` on the connection to disable injection. An explicitly declared container environment variable takes precedence over an automatically generated variable with the same name. Names that collide after uppercasing are rejected. The Azure Recipe stores values in Key Vault and is unchanged by this Kubernetes behavior.

## Recipe Output Properties

The Secrets resource does not have any properties which must be set by a Recipe.

### Azure ACI Key Vault Recipe Outputs

The Azure ACI recipe (`azure-keyvault-secrets.bicep`) provisions an Azure Key Vault and a User Assigned Managed Identity (UAI) with Key Vault Administrator access. It outputs the following values via the Radius `result` object:

| Output Property | Description |
|---|---|
| `keyVaultId` | Resource ID of the created Azure Key Vault |
| `keyVaultUri` | URI of the Key Vault (used by Azure SDK to connect) |
| `userAssignedIdentityId` | Resource ID of the UAI |
| `userAssignedIdentityClientId` | Client ID of the UAI (used in application code) |
| `userAssignedIdentityPrincipalId` | Principal (object) ID of the UAI |

### Azure ACI Recipe Details

- **Key Vault naming**: `kv-<first 7 chars of resource name>-<uniqueString>` (stays within the 3–24 char limit)
- **RBAC authorization**: Enabled on the Key Vault (role assignments, not access policies)
- **Soft delete**: Enabled by default
- **Secret kind validation**: The recipe validates required fields per kind:
  - `certificate-pem`: requires `tls.crt` and `tls.key`
  - `basicAuthentication`: requires `username` and `password`
  - `azureWorkloadIdentity`: requires `clientId` and `tenantId`
  - `awsIRSA`: requires `roleARN`
- **Encoding support**: If a secret entry specifies `encoding: 'base64'`, the value is base64-encoded before storage
- **Parameters**: Accepts an optional `location` parameter (defaults to `resourceGroup().location`)

## Non-developer Use Cases

Secrets are also used by platform engineers to configure authentication for Radius to access Bicep templates stored in OCI registries and Terraform templates stored in Git repositories. This functionality uses the `basicAuthentication`, `awsIRSA`, and `azureWorkloadIdentity` kinds. These Secret kinds should only be used by platform engineers and may change in the future.

See the Radius documentation on [private Bicep registries](https://docs.radapp.io/guides/recipes/howto-private-bicep-registry/) and [private Git repositories](https://docs.radapp.io/guides/recipes/terraform/howto-private-registry/) for details on using these Secret kinds.