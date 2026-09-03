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

### MySQL transport policy

The `Radius.Data/mySqlDatabases` Recipe enforces the resource's `tls` property by passing `--require-secure-transport` to `mysqld`, so the server rejects unencrypted network connections unless the application sets `tls: 'optional'`. Connections over the local Unix socket stay exempt, so the container's first-run initialization still succeeds. The Recipe falls back to `required` when the property is absent, so an older `Radius.Data` namespace registration that predates the `tls` property still yields the secure behavior.

The MySQL server generates its own CA and certificate in its data directory on first start, and the Recipe does not distribute that CA. Clients can therefore encrypt the connection but cannot authenticate the server, so connect with `--ssl-mode=REQUIRED` (mysql CLI) or `ssl: { rejectUnauthorized: false }` (Node.js `mysql2`) rather than a verifying mode. That protects traffic from passive observation but not from an attacker able to intercept connections inside the cluster, so treat this Recipe as development and testing infrastructure and use a Recipe that supplies a trusted certificate where server authentication matters. See [`Data/mySqlDatabases/README.md`](../../Data/mySqlDatabases/README.md#transport-policy) for the full comparison with the managed-database platforms, and for guidance on upgrading a database that existed before enforcement.

This pack pins the `:latest` tag, which tracks stable releases, so Environments using it pick up this enforcement at the next stable Recipe release. The `:edge` tag carries it as soon as the change merges to `main`.

## Deploying

Deploy the pack with the `rad` CLI. Deploying the file creates the `Radius.Core/recipePacks` resource and configures the `default` Environment to use it:

```bash
rad deploy recipe-packs/kubernetes/default-recipepack.bicep
```

After the pack is deployed, every Resource Type it covers can be used in an application deployed to that Environment.

## Contributing a Recipe

To add a Recipe for another Resource Type to this pack, add an entry to the `recipes` map keyed by the Resource Type (for example `Radius.Data/mySqlDatabases`). For guidance on writing Recipes and wiring them into a Recipe Pack, see [Contributing Resource Types and Radius Recipes](../../docs/contributing/contributing-resource-types-recipes.md#recipes-and-recipe-packs).
