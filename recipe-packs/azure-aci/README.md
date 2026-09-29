# Azure ACI Recipe Pack

This directory contains the **Azure ACI Recipe Pack**, a collection of Recipes that provision Radius Containers on Azure Container Instances (ACI), together with the Azure-backed volume and secret stores those workloads use.

| File | Description |
| --- | --- |
| `azure-aci.bicep` | Recipe Pack wiring the Bicep recipes for the ACI-provisioned Resource Types. |

The pack declares a single `Radius.Core/recipePacks` resource whose `recipes` map contains an entry per Resource Type. It does not define an Environment; reference the pack from an Environment configured with the Azure provider to make its Recipes available.

## Recipes in this pack

| Resource Type | Kind | Source |
| --- | --- | --- |
| `Radius.Compute/containers` | Bicep | `ghcr.io/radius-project/azure-aci-recipes/containers` |
| `Radius.Compute/persistentVolumes` | Bicep | `ghcr.io/radius-project/azure-aci-recipes/persistentvolumes` |
| `Radius.Security/secrets` | Bicep | `ghcr.io/radius-project/azure-aci-recipes/secrets` |

`Radius.Compute/routes` and `Radius.Compute/containerImages` are not yet supported on ACI and are omitted. Data, messaging, storage, and AI Resource Types are not part of this pack.

## Deploying

Create and configure an Environment with the Azure provider first:

```bash
rad env create default \
  --kubernetes-namespace default \
  --preview

rad env update default \
  --azure-subscription-id <subscription-id> \
  --azure-resource-group <resource-group> \
  --preview
```

Deploy the Recipe Pack into that existing Environment. The pack takes no parameters:

```bash
rad deploy recipe-packs/azure-aci/azure-aci.bicep \
  --environment default
```

Finally, associate the pack with the Environment. `--recipe-packs` replaces the Environment's pack list, and each Resource Type can have only one Recipe across the associated packs, so combine `azure-aci` only with packs that do not also provide `Radius.Compute/containers`, `Radius.Compute/persistentVolumes`, or `Radius.Security/secrets`:

```bash
rad env update default \
  --recipe-packs azure-aci \
  --preview
```

After the association is updated, every Resource Type the pack covers can be used in an application deployed to that Environment.
