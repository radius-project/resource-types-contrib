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


## Recipe Output Properties

There are no output properties that should be set by a Recipe for a Persistant Volume resource.


