## Overview
The Radius.Security/secrets Resource Type stores sensitive data such as tokens, passwords, keys, and certificates. It is used by developers as part of their applications as well as by platform engineers to configure authentication for Radius to access Bicep Recipes stored in OCI registries and Terraform Recipes stored in Git repositories.

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Security/secrets`. 

## Recipes

A list of available Recipes for this Resource Type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Bicep | recipes/kubernetes/bicep/kubernetes-secrets.bicep | Alpha |
| Kubernetes | Terraform | recipes/kubernetes/terraform/main.tf | Alpha |


## Recipe Input Properties

Properties for the Secrets resource are provided to the recipe via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.properties.kind` (string, optional): The kind of content of the Secret. This optional property allows the developer to specify what kind of data is stored in the Secret. When not specified, Recipes should assume `generic`. Recipes may store Secrets as key-value pairs or use secret store-specific features to store as other types. For example, certificates may be stored as Kubernetes secrets of type `tls`. 

- `context.properties.data` (object, required): A map of secret names to objects containing values and optional encoding. Each key in the `data` object maps to an object with:
  - `value` (string, required): The secret value.
  - `encoding` (string, optional): Content encoding of the value. Recipes should assume `string` unless `base64` is specified.


## Recipe Output Properties

The Secrets resource does not have any properties which must be set by a Recipe.

## Non-developer Use Cases

Secrets are also used by platform engineers to configure authentication for Radius to access Bicep templates stored in OCI registries and Terraform templates stored in Git repositories. This functionality uses the `basicAuthentication`, `awsIRSA`, and `azureWorkloadIdentity` kinds. These Secret kinds should only be used by platform engineers and may change in the future.

See the Radius documentation on [private Bicep registries](https://docs.radapp.io/guides/recipes/howto-private-bicep-registry/) and [private Git repositories](https://docs.radapp.io/guides/recipes/terraform/howto-private-registry/) for details on using these Secret kinds.