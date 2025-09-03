## Overview
The Radius.Storage/volumes resource type models persistant volumes used by applications.

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Compute/volumes`. 

## Recipes

A list of available Recipes for this Resource Type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Bicep | recipes/kubernetes/bicep/kubernetes-volumes.bicep | Alpha |
| Kubernetes | Terraform | recipes/kubernetes/terraform/main.tf | Alpha |


## Recipe Input Properties

Properties for the Volumes resource are provided to the recipe via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.properties.sizeInGiB` (integer, required): Size in GibiBytes of the persistant volume to be provisioned.


## Recipe Output Properties

Properties that should be set by a Recipe for Persistant Volume resource are:

- `kind`: `"persistent"` — identifies the type of the provisioned volume (this resource represents persistent storage).
- `storageClassName`: the storage profile or class used to provision the volume; platform-specific (for example, a Kubernetes `StorageClass` or a cloud provider volume type).
- `capacity`: requested storage size for the provisioned volume (use Gi/GiB notation, e.g. `1Gi`).
- `accessModes`: the access/attachment modes supported by the volume (platform-specific; examples include `ReadWriteOnce`, `ReadOnlyMany`, `ReadWriteMany`, or single-node vs multi-node attachments).
