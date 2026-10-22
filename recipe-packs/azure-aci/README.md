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

The containers recipe uses the published commit tag
`0c3eaf14e7acc074420e78fda4d66c51541a8145`. This version returns
`result.resources` for cleanup and `result.values.hosts` for connections.
The older `latest` artifact does not return these fields. Main branch
publishes update `edge` and commit tags; only stable releases update `latest`.

When you update the containers recipe, select a published commit tag with
these outputs. Run the Azure pack-entry tests and check that both test
container resources return distinct, nonempty hosts. A successful
deployment alone does not prove that the recipe meets this contract.

## Deploying

Create and configure an Environment with the Azure provider first:

```bash
rad env create default \
  --kubernetes-namespace default

rad env update default \
  --azure-subscription-id <subscription-id> \
  --azure-resource-group <resource-group>
```

Deploy the Recipe Pack into that existing Environment. The pack takes no parameters:

```bash
rad deploy recipe-packs/azure-aci/azure-aci.bicep \
  --environment default
```

Finally, associate the pack with the Environment. `--recipe-packs` replaces the Environment's pack list, and each Resource Type can have only one Recipe across the associated packs, so combine `azure-aci` only with packs that do not also provide `Radius.Compute/containers`, `Radius.Compute/persistentVolumes`, or `Radius.Security/secrets`:

```bash
rad env update default \
  --recipe-packs azure-aci
```

After the association is updated, every Resource Type the pack covers can be used in an application deployed to that Environment.
