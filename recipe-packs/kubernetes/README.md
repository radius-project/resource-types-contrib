# Kubernetes Recipe Pack

This folder contains the **Kubernetes Recipe Pack** — a collection of Recipes that provision Radius Resource Types on Kubernetes, bundled with an Environment definition. Deploying the pack configures a Radius Environment to use the Kubernetes provider and registers the Recipes for every Resource Type it covers.

| File | Description |
| --- | --- |
| `default-recipepack.bicep` | Recipe Pack wiring the Bicep recipes for all Kubernetes-provisioned types, plus the Environment definition. |

Each pack declares a `Radius.Core/recipePacks` resource whose `recipes` map contains an entry for every Resource Type, and a `Radius.Core/environments` resource that references the pack.

## Recipes in this pack

Kube-recipes tagged `:edge` are rebuilt on every push to `main`; `:latest` and the version tags track stable releases.

| Resource Type | Kind | Source |
| --- | --- | --- |
| `Radius.Compute/containers` | Bicep | `ghcr.io/radius-project/kube-recipes/containers:latest` |
| `Radius.Compute/persistentVolumes` | Bicep | `ghcr.io/radius-project/kube-recipes/persistentvolumes:latest` |
| `Radius.Compute/routes` | Bicep | `ghcr.io/radius-project/kube-recipes/routes:latest` |
| `Radius.Security/secrets` | Bicep | `ghcr.io/radius-project/kube-recipes/secrets:latest` |
| `Radius.Data/mySqlDatabases` | Bicep | `ghcr.io/radius-project/kube-recipes/mysqldatabases:latest` |
| `Radius.Data/redisCaches` | Bicep | `ghcr.io/radius-project/kube-recipes/rediscaches:latest` |
| `Radius.Messaging/rabbitMQ` | Bicep | `ghcr.io/radius-project/kube-recipes/rabbitmq:latest` |

## MySQL transport policy

The MySQL Recipe enforces `tls: 'required'` (the default) by rejecting
plaintext TCP connections. `tls: 'optional'` permits plaintext without
disabling TLS. It uses the MySQL image's generated certificates, which do
not provide verified server identity for the Kubernetes Service hostname.
See [MySQL transport enforcement and certificate trust](../../Data/mySqlDatabases/README.md#transport-enforcement-and-certificate-trust)
for client configuration and the limits of these development certificates.

Recipes published before this change ignore `tls`. Use an artifact containing
the fix and redeploy the database; merging source does not update existing
servers or stable recipe tags. The new server arguments cause a pod rollout,
and this Recipe has no explicit persistent data volume. Protect existing
data and configure clients for TLS before upgrading. See
[upgrading existing deployments](../../Data/mySqlDatabases/README.md#upgrading-existing-deployments).

## Deploying

Deploy the pack with the `rad` CLI. Deploying the file creates the `Radius.Core/recipePacks` resource and configures the `default` Environment to use it:

```bash
rad deploy recipe-packs/kubernetes/default-recipepack.bicep
```

After the pack is deployed, every Resource Type it covers can be used in an application deployed to that Environment.

## Contributing a Recipe

To add a Recipe for another Resource Type to this pack, add an entry to the `recipes` map keyed by the Resource Type (for example `Radius.Data/mySqlDatabases`). For guidance on writing Recipes and wiring them into a Recipe Pack, see [Contributing Resource Types and Radius Recipes](../../docs/contributing/contributing-resource-types-recipes.md#recipes-and-recipe-packs).
