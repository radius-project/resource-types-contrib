# Azure Recipe Pack

This folder contains the **Azure Recipe Pack** — a collection of Recipes that provision Radius Resource Types on Azure, bundled with an Environment definition. Deploying the pack configures a Radius Environment to use the Azure provider and registers the Recipes for every Resource Type it covers.

| File | Description |
| --- | --- |
| `bicep-recipepack.bicep` | Recipe Pack wiring the Bicep recipes for all Azure-provisioned types, plus the Environment definition. |

Each pack declares a `Radius.Core/recipePacks` resource whose `recipes` map contains an entry for every Resource Type, and a `Radius.Core/environments` resource that references the pack and configures the Azure provider.

## Recipes in this pack

| Resource Type | Kind | Source |
| --- | --- | --- |
| `Radius.Messaging/kafka` | Bicep | Azure Verified Module — `avm/res/event-hub/namespace` |
| `Radius.Data/mongoDatabases` | Bicep | Azure Verified Module — `avm/res/document-db/database-account` |
| `Radius.Data/mySqlDatabases` | Bicep | Azure Verified Module — `avm/res/db-for-my-sql/flexible-server` |
| `Radius.Compute/containers` | Bicep | `ghcr.io/radius-project/kube-recipes/containers` |

## Parameters

The Azure pack accepts the provider configuration it needs to provision into your subscription:

| Parameter | Description |
| --- | --- |
| `azureSubscriptionId` | Azure subscription ID the Environment provisions resources into. |
| `azureResourceGroup` | Existing Azure resource group the Environment provisions resources into. |

## Deploying

Deploy the pack with the `rad` CLI, supplying the parameters it requires. Deploying the file creates the `Radius.Core/recipePacks` resource and configures the `default` Environment to use it:

```bash
rad deploy recipepack/azure/bicep-recipepack.bicep \
  --parameters azureSubscriptionId=<subscription-id> \
  --parameters azureResourceGroup=<resource-group>
```

After the pack is deployed, every Resource Type it covers can be used in an application deployed to that Environment.

## Contributing a Recipe

To add a Recipe for another Resource Type to this pack, add an entry to the `recipes` map keyed by the Resource Type (for example `Radius.Data/mySqlDatabases`). For guidance on writing Recipes and wiring them into a Recipe Pack, see [Contributing Resource Types and Radius Recipes](../../docs/contributing/contributing-resource-types-recipes.md#recipes-and-recipe-packs).
