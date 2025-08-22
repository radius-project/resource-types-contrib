## Overview
The Radius.Storage/volumes resource type models persistant volumes used by applications.

## Resource Type Schema Definition

The Resource Type schema for Redis is defined in the `volume.yaml` file.

Input properties include:

- environment: Resource ID of the target environment.
- application: Resource ID of the application.
- size (string, required): Size of the persistent volume. For example 1Gi. Valid suffixes are Ki, Mi, Gi, Ti, Pi, Ei, K, M, G, T, P, E. 

Output properties include:

- hostPath: An absolute path on the Kubernetes node (the host filesystem).
- accessMode: Access mode for the volume. Controls how a persistent volume can be mounted by pods (e.g., ReadWriteOnce = single node R/W, ReadOnlyMany = many nodes R/O, ReadWriteMany = many nodes R/W).
- storageClass: StorageClass of the volume

## Examples

```
extension radius
extension radiusResources

param environment string
param location string = 'global'

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'corerp-resources-app'
  location: location
  properties: {
    environment: environment
  }
}

resource volume 'Radius.Storage/volumes@2025-05-01-preview' = {
  name: 'corerp-resources-volume'
  properties: {
    application: app.id
    environment: environment
    size: '1Gi'
  }
}


```

## Recipes

Below is a summary of the available Recipes for the Redis Resource Type, categorized by platform and Infrastructure as Code (IaC) language. 

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| Kubernetes | Bicep | kubernetes-volume.bicep | Alpha |
| Kubernetes | Terraform | kubernetes/main.tf | Alpha |

## Guidance

- The given recipe is suitable for simple setups. Switch to NFS/CSI/Azure Files if you need RWX or multi-node sharing in production. 
