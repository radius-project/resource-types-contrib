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

## Recipe revision and upgrades

All three sources are pinned to the published commit
[`31e17276ac5261b6c22a375edbc3122b9a09b6ea`](https://github.com/radius-project/resource-types-contrib/commit/31e17276ac5261b6c22a375edbc3122b9a09b6ea),
not the floating `latest` alias. This revision includes the containers fix from
[#356](https://github.com/radius-project/resource-types-contrib/issues/356):
default Azure infrastructure names include both the resource-group ID and the
Radius resource ID, and the recipe returns the Radius `result.resources` and
`result.values` contract. A pullable older `latest` artifact is not sufficient.

When updating the pins, use a full commit SHA already published by
**Publish Bicep Recipes**, verify all three artifacts are public, and inspect
the compiled containers module for those naming and output contracts. Update
all three sources together and retain the referenced artifacts. A pack release
bundles the source references, not the recipe modules; it does not publish them
or advance `latest`.

For an existing ACI deployment using the older containers recipe, the new
default names can provision replacement infrastructure instead of reusing the
old resources. Before updating the pack, inventory existing Azure resources
and saved Radius deployment state, plan workload/data migration and cleanup,
and verify the upgrade in a dedicated environment. Do not assume redeploying
the pack migrates application resources or deletes old infrastructure. Consumers
of the former flat infrastructure outputs must adapt: those fields were removed,
tracked resource IDs are in `result.resources`, and connection hosts are in
`result.values.hosts` when the container exposes a port.

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
