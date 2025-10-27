## Overview
The Radius.Compute/persistentVolumes Resource Type represents a persistent storage volume.

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Compute/volumes`. 

## Recipes

A list of available Recipes for this Resource Type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Bicep | recipes/kubernetes/bicep/kubernetes-volumes.bicep | Alpha |
| Kubernetes | Terraform | recipes/kubernetes/terraform/main.tf | Alpha |


## Recipe Input Properties

Properties for PersistentVolumes are provided to the Recipe via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.properties.sizeInGib` (integer, required): Size in gibibyte of the PersistentVolume to be deployed.
- `context.properties.allowedAccessModes` (string, optional): Restricts which access mode a consuming container may request. If omitted, the Kubernetes recipes default to `ReadWriteOnce` so that dynamic provisioners such as Azure Disk can bind the claim.
- `context.properties.environment` (string, optional): Used for labeling. The recipes shorten the environment resource ID to the final segment to satisfy Kubernetes label length and character restrictions.


## Recipe Output Properties

The Kubernetes recipes emit the following output values:

- `claimName` (string): Normalized PersistentVolumeClaim name created by the recipe. Container recipes can depend on this via a Radius connection to automatically populate `claimName` when only `resourceId` is provided.


