## Overview
The Radius.Compute/persistentVolumes Resource Type represents a persistent storage volume.

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Compute/volumes`. 

## Recipes

A list of available Recipes for this Resource Type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Azure (ACI) | Bicep | recipes/azure-aci/bicep/azure-aci-volumes.bicep | Alpha |
| Kubernetes | Bicep | recipes/kubernetes/bicep/kubernetes-volumes.bicep | Alpha |
| Kubernetes | Terraform | recipes/kubernetes/terraform/main.tf | Alpha |


## Recipe Input Properties

Properties for PersistentVolumes are provided to each Recipe via the [Recipe Context](https://docs.radapp.io/reference/context-schema/) object. These properties include:

- `context.properties.sizeInGib` (integer, required): Size in gibibyte of the PersistentVolume to be deployed.
- `context.properties.allowedAccessModes` (string, optional): Restricts which access mode a consuming container may request. If omitted, the Kubernetes recipes default to `ReadWriteOnce` so that dynamic provisioners such as Azure Disk can bind the claim.
- `context.properties.environment` (string, optional): Used for labeling. The recipes shorten the environment resource ID to the final segment to satisfy Kubernetes label length and character restrictions.

The Azure ACI Bicep recipe also supports these optional parameters:

- `location` (string): Azure location for the Storage Account and File Share. Defaults to `resourceGroup().location`.
- `storageSku` (string): Storage SKU for the Storage Account. Defaults to `Standard_LRS`.
- `storageKind` (string): Storage account kind. Defaults to `StorageV2`.


## Recipe Output Properties

The Kubernetes recipes emit the following output values:

- `claimName` (string): Normalized PersistentVolumeClaim name created by the recipe. Container recipes can depend on this via a Radius connection to automatically populate `claimName` when only `resourceId` is provided.

The Azure ACI Bicep recipe emits the following output values and secrets:

- `values.provider` (string): Set to `azureFile`.
- `values.storageAccountName` (string): Storage account that hosts the Azure File Share.
- `values.shareName` (string): Azure File Share name to mount from ACI containers.
- `values.shareQuotaGiB` (integer): File share quota configured from `sizeInGib`.
- `values.allowedAccessModes` (string): Effective access mode constraints from the PersistentVolume resource (empty when not set).
- `secrets.storageAccountKey` (string): Storage account key for mounting the Azure File Share.


