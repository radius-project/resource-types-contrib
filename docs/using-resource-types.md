# Discovering and Using Resource Types and Recipe Packs

This guide is for developers and platform engineers who want to find the Resource Types and Recipe Packs available in this repository and use them with Radius. Developers use Resource Types in their application definitions; platform engineers use Recipe Packs to configure how those types are provisioned in an Environment. If you want to contribute a new Resource Type or Recipe, see [Contributing Resource Types and Recipes](contributing/contributing-resource-types-recipes.md) instead.

## Discovering Resource Types

Resource Types in this repository are organized by category. Each category maps to a `Radius.<Category>` namespace and lives in a top-level directory (for example, `Data/`, `Security/`, `Compute/`). Within a category, each Resource Type has its own folder that contains:

- `<resourceType>.yaml` — the Resource Type definition, including developer documentation and usage examples in its top-level `description`.
- `README.md` — an overview written for platform engineers, describing the properties a Recipe consumes and produces, and referencing the Recipe Packs and the tested Recipe sources (modules) available for the type.
- `test/app.bicep` — a runnable example application that uses the Resource Type.

To browse the available types, explore the category directories in this repository, or list them from an environment where they are registered:

```bash
# List the Resource Types registered in your Radius installation
rad resource-type list

# Show the developer documentation, properties, and usage examples for a type
rad resource-type show Radius.Data/mySqlDatabases
```

The output of `rad resource-type show` includes the Bicep usage example and a description of every property, so it is the fastest way to learn how to use a type once it is registered.

## Registering a Resource Type

Some Resource Types ship as defaults in Radius and are available out of the box (see [Default resource types in Radius](../README.md#default-resource-types-in-radius)). If the type you want is not already registered, register it from its definition:

```bash
rad resource-type create Radius.Data/mySqlDatabases -f Data/mySqlDatabases/mySqlDatabases.yaml
```

Registering the type also makes it available in Bicep through the generated extension. Your platform engineer must also configure a Recipe for the type in your Environment — Recipes for this repository are grouped into the platform Recipe Packs under [`recipe-packs/`](../recipe-packs/).

## Discovering and using Recipe Packs

Recipe Packs live at the repository root under [`recipe-packs/`](../recipe-packs/). Each platform has its own folder containing a default Recipe Pack that can wire both Bicep and Terraform recipes:

- `azure/` — recipes for all types provisioned on Azure.
- `aws/` — recipes for all types provisioned on AWS.
- `kubernetes/` — recipes for all types provisioned in-cluster on Kubernetes.

Each Recipe Pack bundles the Recipes for every Resource Type on that platform into a reusable `Radius.Core/recipePacks` resource. Recipe Pack files do not create or modify Environments. A platform engineer creates and configures an Environment separately, deploys the pack, and then associates the pack with the Environment instead of registering Recipes one type at a time.

For example, create an Azure-backed Environment:

```bash
rad env create default \
  --kubernetes-namespace default \
  --preview

rad env update default \
  --azure-subscription-id <subscription-id> \
  --azure-resource-group <resource-group> \
  --preview
```

Then deploy and associate the Azure Recipe Pack:

```bash
rad deploy recipe-packs/azure/aks-recipepack.bicep \
  --environment default \
  --parameters routesGatewayName=<gateway-name> \
  --parameters containerImagesRegistry=<registry-path>

rad env update default \
  --recipe-packs azure-avm \
  --preview
```

For the zero-config Kubernetes default, create the Environment with `rad env create`, deploy `recipe-packs/kubernetes/default-recipepack.bicep`, and associate the `default` pack in the same way. After association, every Resource Type the pack covers can be used in an application deployed to that Environment.

## Using a Resource Type in a Radius application

Once a Resource Type is registered and a Recipe is configured in your Environment, add it to your application definition:

1. **Reference the extension** for the Resource Type at the top of your Bicep file.
2. **Declare the resource**, providing the required properties. `environment` is always required, and `application` is required for types that belong to an application.
3. **Connect to the resource** from a container, so Radius injects the connection details as environment variables.
4. **Deploy** the application.

```bicep
extension radius
extension mysqlDatabases

@description('The Radius environment ID')
param environment string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'myapp'
  properties: {
    environment: environment
  }
}

resource db 'Radius.Data/mySqlDatabases@2025-08-01-preview' = {
  name: 'db'
  properties: {
    environment: environment
    application: app.id
    database: 'appdb'
  }
}

resource frontend 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'frontend'
  properties: {
    environment: environment
    application: app.id
    containers: {
      web: {
        image: 'ghcr.io/radius-project/samples/demo:latest'
        ports: {
          web: {
            containerPort: 3000
          }
        }
      }
    }
    connections: {
      db: {
        source: db.id
      }
    }
  }
}
```

Deploy the application with the `rad` CLI:

```bash
rad deploy app.bicep
```

When a container declares a `connection` to a resource, Radius can inject the resource's ordinary connection properties into the container as environment variables named `CONNECTION_<CONNECTION-NAME>_<PROPERTY-NAME>` (for example `CONNECTION_DB_HOST` and `CONNECTION_DB_PORT`).

With [compatible Radius control-plane support](https://github.com/radius-project/radius/issues/12709) and Kubernetes Container Recipe support from [#300](https://github.com/radius-project/resource-types-contrib/pull/300) or later, the same connection also injects Recipe secrets as individual `valueFrom.secretKeyRef` variables. For example, a Redis connection named `redis` provides ordinary `CONNECTION_REDIS_HOST` and `CONNECTION_REDIS_PORT` values plus the secret-backed `CONNECTION_REDIS_URL`. Radius passes only Secret reference metadata to the Container Recipe, so secret values are never copied into container configuration or Recipe output. The Azure ACI Recipe is unchanged.

Secret ownership does not change: developers continue to author credential inputs, including `Radius.Security/secrets` resources referenced through `<secret>.id`, while Recipes return only infrastructure-generated credentials through `result.secrets`. The producer's `properties.secrets.name` is the materialized Kubernetes Secret name for explicit `secretKeyRef` wiring; it is not a resource ID or a second connection source.

This support is additive and does not require existing applications to migrate. Explicit `env` entries, native `value` and `valueFrom.secretKeyRef` variables, direct connections to user-authored `Radius.Security/secrets` resources, and `disableDefaultEnvVars` remain supported. Explicit container environment variables take precedence over generated variables. Otherwise a managed secret reference takes precedence over an ordinary property that produces the same name. Set `disableDefaultEnvVars: true` to disable both ordinary and secret-backed variables for a connection. Generated names must remain unique after uppercasing.

The automatic projection applies to regular and init containers rendered by compatible Kubernetes Container Recipes. On older or mixed control-plane and Recipe versions, retain explicit `env` or `secretKeyRef` wiring until both sides support the contract.

## Finding examples

Every Resource Type folder includes a `test/app.bicep` that shows a complete, working example, and the type's `README.md` documents its properties. Start from the example for the type you want, then adapt it to your application.

## Learn more

- [Radius documentation](https://docs.radapp.io)
- [Resource Types tutorial](https://docs.radapp.io/tutorials/create-resource-type/)
- [Connections between resources](https://docs.radapp.io/guides/author-apps/connections/)
