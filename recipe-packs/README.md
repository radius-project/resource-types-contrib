# Recipe Packs

A **Recipe Pack** is a manifest of recipes by Resource Type referenced in a Radius Environment. Each pack is a directory under `recipe-packs/` containing:

- `<name>-recipe-pack.bicep`: declares one `Radius.Core/recipePacks` resource whose `recipes` map has an entry per Resource Type.
- `README.md`: documents the pack, its parameters, and the recipes it includes.

## Available Recipe Packs

| Pack | Directory | Container platform | Other resource types |
| --- | --- | --- | --- |
| Kubernetes (default) | [`kubernetes/`](kubernetes/) | Kubernetes | Kubernetes |
| Azure AKS | [`azure-aks/`](azure-aks/) | Kubernetes | Azure managed services |
| Azure ACI | [`azure-aci/`](azure-aci/) | Azure Container Instances | Azure Files and Key Vault only |

## The default Recipe Pack

`rad init` installs the **Kubernetes Recipe Pack** ([`kubernetes/default.bicep`](kubernetes/default.bicep)) as the `default` pack (it embeds its own copy, kept in sync with this file), so a fresh Radius installation needs no extra configuration.

## How to create a new Recipe Pack

1. **Create the folder and files.** Add `recipe-packs/<pack-name>/` with a `<name>-recipe-pack.bicep` and a `README.md`. Use a folder name that identifies the platform and, where a cloud offers more than one compute target, the compute runtime (for example `azure-aks`, `azure-aci`, `kubernetes`). Name the Bicep file `<short-name>-recipe-pack.bicep`.
2. **Declare the pack.** In the Bicep file, declare a single `Radius.Core/recipePacks` resource whose `recipes` map has an entry keyed by each Resource Type (for example `Radius.Data/redisCaches`).
3. **Wire each Recipe.** Point each entry at its module `source` and map `parameters` (using `{{context.*}}` expressions) and `outputs`. Reuse published modules such as Azure Verified Modules where possible, and reference in-repo Bicep recipes by their published OCI image.
4. **Publish any in-repo Bicep recipes** the pack references by adding them to [`.github/workflows/publish-bicep-recipes.yaml`](../.github/workflows/publish-bicep-recipes.yaml) so the `source` images exist.
5. **Enable releases.** Add the new folder name to the `recipe_pack` choice list in [`.github/workflows/release-recipe-pack.yaml`](../.github/workflows/release-recipe-pack.yaml). Packs are otherwise discovered automatically: any folder under `recipe-packs/` that holds at least one `.bicep` file is treated as a releasable pack.
6. **Document it.** Give the pack a `README.md` following the existing packs, listing its parameters and the Recipes it wires.

For guidance on authoring the Recipes themselves, see [Contributing Resource Types and Radius Recipes](../docs/contributing/contributing-resource-types-recipes.md#recipes-and-recipe-packs).
