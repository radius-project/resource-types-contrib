## Recipe Description

This recipe provisions an Azure Storage Account and an Azure File Share for use as a `Radius.Compute/persistentVolumes` resource in Azure Container Instances environments.

The recipe uses `context.resource.properties.sizeInGib` to set the file share quota.

## Usage Instructions

- Register this Bicep recipe for `Radius.Compute/persistentVolumes` in your Azure-backed Radius environment.
- Connect a `Radius.Compute/containers` resource to the persistent volume resource.
- Use the output values and secret from this recipe (`shareName`, `storageAccountName`, `storageAccountKey`) to configure Azure File volume mounts in your ACI container recipe.
