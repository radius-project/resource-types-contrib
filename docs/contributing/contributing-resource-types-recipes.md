# Contributing Resource Types and Recipes to Radius

This guide walks you through the process of creating and contributing Radius Resource Types and Recipes to this repository.

## Prerequisites

Before you begin, ensure you have a basic understanding of Radius concepts and the IaC languages you plan to use (Bicep or Terraform).

- Familiarize yourself with the [Radius](https://docs.radapp.io)
- Familiarize yourself with the [Resource Types](https://docs.radapp.io/concepts/resource-types/) and [Radius Recipes](https://docs.radapp.io/concepts/recipes/) concept

## Overview

Contributing a Resource Type and Recipe involves the following:

1. [**Resource Type Definition**](#resource-type-definition): Defines the structure and properties of your Resource Type
2. [**Recipes and Recipe Packs**](#recipes-and-recipe-packs): The Recipe that deploys the Resource Type, it could be a Recipe written from scratch or an existing module as Recipe added to the platform Recipe Packs
3. [**Documentation**](#document-your-resource-type-and-recipes): Providing clear usage examples and instructions
4. [**Testing**](testing-resource-types-recipes.md): Ensuring your Resource Type works as expected in a Radius Environment
5. [**Submission**](submitting-contribution.md): Creating a pull request with your changes

## Resource Type Definition

### 1. Choose a Resource Type

Identify the Resource Type you want to contribute. It could be a database, messaging service, or any other resource that fits within the Radius ecosystem. You can pick from the open issues in this repository or propose a new Resource Type.

### 2. Create a fork and clone this Repository

Create a fork of the `resource-types-contrib` repository on GitHub, then clone your fork to your local machine:

```bash
git clone https://github.com/<your-username>/resource-types-contrib.git
```

### 3. Create a new Resource Type directory

Create a new directory for your Resource Type under the appropriate category. Your Resource Type directory holds the schema definition, platform-engineer documentation, and a test application. The Recipes that deploy your Resource Type are added to the shared Recipe Packs at the repository root. For example, if you are contributing a new `redisCaches` Resource Type, the layout should look like this:

```
resource-types-contrib/
├── Data/
│   └── redisCaches/
│       ├── redisCaches.yaml         # Resource Type definition
│       ├── README.md                # Documentation for platform engineers
│       └── test/
│           └── app.bicep            # Developer-facing test application
└── recipe-packs/                      # Recipe Packs cover recipes for all types in the repo
    ├── azure/                        # Azure recipe pack (recipes for all types + environment)
    │       ├── README.md                  # Documentation for the Azure recipe pack
    │       └── aks-recipepack.bicep   # Recipe pack wiring Bicep and Terraform recipes
    ├── aws/                          # AWS recipe pack
    │       ├── README.md
    │       └──eks-recipepack.bicep
    └── kubernetes/           # Default recipe pack (zero-config, in-cluster)
            ├── README.md
            └── default-recipepack.bicep
```

### 4. Define Your Resource Type Definition

For example, if you are contributing to a `redisCaches` Resource Type, create a `redisCaches.yaml` file that defines the `redisCaches` Resource Type. The initial version may look similar to:

```yaml
namespace: Radius.Data
types:
  redisCaches:
    apiVersions:
      '2025-08-01-preview':
        schema:
          type: object
          properties:
            environment:
              type: string
            application:
              type: string
            capacity:
              type: string
              enum: [S, M, L, XL]
            host:
              type: string
              readOnly: true
            port:
              type: string
              readOnly: true
            username:
              type: string
              readOnly: true
            secrets:
              type: object
              properties:
                password:
                  type: string
                  readOnly: true
        required:
            - environment
            - application
```

#### Schema Guidelines

The following guidelines should be followed when contributing new Resource Types:

- The `namespace` field follows the format `Radius.<Category>`, where `<Category>` is a high-level grouping (e.g., Data, Dapr, AI). Some examples might be `Radius.Data/*` or `Radius.Security/*`.

- The Resource Type name follows the camelCase convention and is in plural form, such as `redisCaches`, `sqlDatabases`, or `rabbitMQQueues`.

- Version should be the latest date and follow the format `YYYY-MM-DD-preview`. This is the date on which the contribution is made or when the Resource Type is tested and validated, e.g. `2025-07-20-preview`.

- The description property must be populated with developer documentation. The top-level descrption and each property's description are output by `rad resource-type show` and will be visible in the Radius Dashboard in the future. See documentation section for more details.

- Each Resource Type will have one or more common properties:
  - `environment` must always be a required property (include in the `required` property).
  - `application` may be a required or property:
    - Required: Use when a resource must always be part of an application. For example, a Container will always be part of an application.
    - Not required: Do not include in the `required` property for resources that may be deployed to an Environment without an application with the intention of being a shared resource. A blob store, for example, may be shared across multiple containers and applications.

- Each additional properties must:
  - Follow the camelCase naming convention.
  - Include a description for each property (see documentation section for more details).
  - Properties that are required must be listed in the `required` block.
  - Properties that are set by the Recipe only after the resource is deployed must be marked as `readOnly: true`.
  - Have a `type`. Valid types are:`integer`, `string`, `object`, `enum`, and `array`.
  - Properties that contain sensitive data such as passwords, tokens, or keys must be marked with `x-radius-sensitive: true`. This annotation can be applied to properties of type `string` or `object`. Radius will encrypt the data using the `radius-encryption-key` secret and store it temporarily in the Radius data store; it will be deleted during deployment processing.

- Resource Types are made for developers and must be application-oriented. Avoid infrastructure-specific or platform-specific properties. Make sure the schema is simple and intuitive, avoiding unnecessary complexity.

### 5. Add a Resource Type Icon

Add a monochrome SVG icon named `<resourceTypeName>.svg` to the Resource Type directory, next to its YAML definition. The icon must support both light and dark mode.

Radius treats icons as untrusted content and validates them against a small SVG allowlist. Icons **must not** contain a `<style>` element or a `style` attribute, because CSS can carry network-capable constructs such as `@import` and `url()`. An icon that violates this is rejected at registration time. Presentation attributes such as `fill` and `stroke` are the supported way to style an icon.

Because CSS is unavailable, express the icon as a luminance `<mask>` and paint it with `currentColor`:

```svg
<svg width="500" height="500" viewBox="0 0 500 500" fill="none" xmlns="http://www.w3.org/2000/svg">
  <mask id="<resourceTypeName>-icon" maskUnits="userSpaceOnUse" x="0" y="0" width="500" height="500">
    <!-- Artwork. White is the visible ink, black is a transparent knockout. -->
    <path d="..." fill="white"/>
    <path d="..." fill="black"/>
  </mask>
  <rect x="0" y="0" width="500" height="500" fill="currentColor" mask="url(#<resourceTypeName>-icon)"/>
</svg>
```

Inside the mask, white areas become visible ink and black areas become transparent holes. The single `<rect>` paints that silhouette in `currentColor`, so the icon inherits the surrounding text color: dark ink on a light surface and light ink on a dark one. Nothing in the icon is painted an opaque white, so the host background always shows through the knockouts.

Two rules follow from this structure:

- Give the mask an `id` derived from the icon file name. Icons are often inlined into the same page, and duplicate `id` values collide across documents.
- Never fill a shape with an opaque `white` to knock out detail. Put it in the mask as `black` instead, so the hole is genuinely transparent rather than white.

Verify the icon on a light background with dark surrounding text and on a dark background with light surrounding text. Run `make validate-icons` for a fast preflight; the full resource type build performs authoritative Radius validation.

## Document Your Resource Type and Recipes

Each Resource Type has two types of documentation written specifically for developers, and separately, for platform engineers.

### Developers

Developer documentation is embedded in the Resource Type definition. Each Resource Type definition must have documentation on how and when to use the resource in the top-level description property. When writing developer documentation, use Markdown. This is especially important for code blocks which must be quoted using triple backquotes. Every code block must include a language annotation immediately after the opening backticks (for example ` ```bicep `, ` ```json `, or ` ```yaml `) so it renders with correct syntax highlighting on docs.radapp.io. Most code blocks in a description are Bicep examples and should use ` ```bicep `. Output from `rad resource-type show` is shown in text only, but the Radius Dashboard formats the Markdown property including the ability to single-click copy code blocks.

Each property must also include:

- The overall description of the property including example values.
- Whether the property is required or optional.

When setting the description of properties:

- **Prefix each description** with `(Required)`, `(Optional)`, or `(Read Only)` to match how the property is defined in the schema. Keep the prefix in sync with the schema's `required` array and `readOnly` flag.
- **Wrap literal values in backticks**: enum members, defaults, property names, type names, and file names (for example `` `false` ``, `` `Radius.Core/environments` ``). Leave ordinary words unquoted.
- **State the default, if any**, at the end of the description as `` Defaults to `<value>` if not specified. `` This applies to all property types.
- **Don't restate the schema.** For enums, omit the list of accepted values; they surface through IntelliSense in VS Code and in the resource type schema. Describe what the property does, not what values it accepts.
- **Keep descriptions unquoted.** Write property descriptions as plain, unquoted text. Do not use `:` or `#`. Ordinary punctuation such as commas, hyphens, parentheses, periods, and slashes are acceptable. If a description needs a colon or other special punctuation, use a `description: |` block.

For example, the initial `redisCaches` Resource Type from above must be enhanced with developer documentation:

```yaml
namespace: Radius.Data
types:
  redisCaches:
    description: |
      The Radius.Data/redisCaches Resource Type adds a Redis cache to an application. Start by adding a redisCaches resource to your application definition Bicep file:

      ```bicep
      resource redis 'Radius.Data/redisCaches@2025-08-01-preview' = {
        name: 'redis'
        properties: {
          application: todolist.id
          environment: environment
          capacity: 'M'
        }
      }
      ```

      Then add a connection from a Container resource to the Redis resource.

      ```bicep
      resource myContainer 'Radius.Compute/containers@2025-08-01-preview' = {
        name: 'myContainer'
        properties: { ... }
        connections: {
          redis: {
            source: redis.id
          }
        }
      }
      ```
    apiVersions:
      '2025-08-01-preview':
        schema:
          type: object
          properties:
            environment:
              type: string
              description: (Required) The Radius Environment ID. Typically set by the rad CLI. Typically value should be `environment`.
            application:
              type: string
              description: (Required) The Radius Application ID. `todolist.id` for example.
            capacity:
              type: string
              enum: [S, M, L, XL]
              description: (Optional) The capacity of the Redis cache.
            host:
              type: string
              readOnly: true
              description: (Read Only) The hostname used to connect to the Redis server.
            port:
              type: string
              readOnly: true
              description: (Read Only) The network port used to connect of the Redis server.
            username:
              type: string
              readOnly: true
              description: (Read Only) The username used to connect to Redis server.
            secrets:
              type: object
              properties:
                password:
                  type: string
                  readOnly: true
                  description: (Read Only) The password used to connect to the Redis server.
          required:
            - environment
            - application
```

### Platform Engineers

Documentation for platform engineers must be provided in a `README.md` file in the Resource Type directory. This README should focus on describing the Recipes provided for the Resource Type across the platform Recipe Packs and the requirements for authoring a custom Recipe. This file should include:

```
## Overview

A brief description of the Resource Type and its purpose.

## Recipes

A list of the Recipes provided for this Resource Type, including the platform Recipe Pack that contains each one and the module the Recipe points to:

| Platform | Recipe Pack | Module Source |
|---|---|---|
| Azure | recipe-packs/azure/aks-recipepack.bicep | mcr.microsoft.com/bicep/avm/res/cache/redis-enterprise |
| AWS | recipe-packs/aws/eks-recipepack.bicep | ... |
| Kubernetes | recipe-packs/kubernetes/default-recipepack.bicep | ghcr.io/radius-project/kube-recipes/... |

## Recipe Input Properties

A list of properties set by developers and a description of their purpose when authoring a Recipe.

## Recipe Output Properties

A list of read-only properties which are required to be set by the Recipe.
```

Create a `README.md` file in each Recipe directory to provide specific instructions for using that Recipe. Include:

```
## Recipe Description
A brief description of what the Recipe does and how to use it.

## Usage Instructions

```

### Documentation Guidelines

- Include overview of the Resource Type and its purpose
- Provide clear instructions for using the Resource Type and Recipes
- Document any special requirements or limitations
- Provide troubleshooting guidance
- Link to relevant external documentation

## Recipes and Recipe Packs

Recipes for a Resource Type are added to the platform Recipe Packs under `recipe-packs/` at the repository root. Each platform has its own folder (`azure/`, `aws/` ,  and `kubernetes/`) containing a single Recipe Pack (`default-recipepack.bicep`) that wires both Bicep and Terraform recipes. Each Recipe Pack declares a single `Radius.Core/recipePacks` resource whose `recipes` map contains an entry for every Resource Type, plus a `Radius.Core/environments` resource that references the pack.

Today Radius supports Bicep and Terraform Recipe drivers, so a Recipe can be a Bicep template or a Terraform configuration. It can also point to well-maintained community modules like the [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/) or the [AWS Terraform modules](https://registry.terraform.io/namespaces/terraform-aws-modules). When pointing at a standard module, Radius resolves any `{{context.*}}` expressions in the Recipe's `parameters` against the resource being deployed and maps the module's outputs onto the resource's read-only properties via the `outputs` field, so no Radius-specific wrapping is required.

For Azure resources whose names must be globally unique, `{{context.azure.resourceNameHash}}` returns the first 16 lowercase hexadecimal characters of a SHA-256 hash over the lowercased Azure resource-group ID and Radius resource ID. This gives Recipes a stable suffix that meets the naming restrictions of the Azure services in this Recipe Pack.

- Familiarize yourself with the IaC language of your choice, [Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview?tabs=bicep) or [Terraform](https://developer.hashicorp.com/terraform)
- Familiarize yourself with the Radius [Recipe](https://docs.radapp.io/guides/recipes) concept
- Follow this [how-to guide](https://docs.radapp.io/guides/recipes/howto-author-recipes/) to write your first Recipe

### Example Recipe Pack

The example below shows an Azure Recipe Pack (`recipe-packs/azure/default-recipepack.bicep`) that registers a Recipe for `Radius.Data/redisCaches` pointing at a standard Azure Verified Module, and a Recipe for `Radius.Compute/containers` using a published Kubernetes container recipe. The developer-authored `size` property is mapped onto a concrete SKU, and the module's outputs are mapped back onto the resource's `host`, `port`, and `url` properties.

```bicep
extension radius

@description('Azure subscription ID the environment provisions resources into.')
param azureSubscriptionId string

@description('Azure resource group the environment provisions resources into. Must already exist.')
param azureResourceGroup string

resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'redis-azure-avm'
  properties: {
    recipes: {
      'Radius.Data/redisCaches': {
        kind: 'bicep'
        // Standard Azure Verified Module, version pinned with `:<tag>`
        source: 'mcr.microsoft.com/bicep/avm/res/cache/redis-enterprise:0.5.1'
        parameters: {
          // Redis Enterprise names are global, so use a stable hash-based name
          // prefixed with the Cloud Adoption Framework abbreviation (amr = Azure Managed Redis)
          name: 'amr-{{context.azure.resourceNameHash}}'
          // Map the developer-authored `size` enum onto a concrete SKU
          skuName: '{{context.resource.properties.size == "S" ? "Balanced_B0" : "Balanced_B1"}}'
          database: {
            name: 'default'
            accessKeysAuthentication: 'Enabled'
          }
          publicNetworkAccess: 'Enabled'
          enableTelemetry: false
        }
        // Map module outputs onto the resource's read-only properties
        outputs: {
          host: 'hostName'
          port: 'port'
          url: 'primaryConnectionString'
        }
      }
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containers:latest'
      }
    }
  }
}

resource env 'Radius.Core/environments@2025-08-01-preview' = {
  name: 'default'
  properties: {
    providers: {
      azure: {
        subscriptionId: azureSubscriptionId
        resourceGroupName: azureResourceGroup
      }
      kubernetes: {
        namespace: 'default'
      }
    }
    recipePacks: [
      recipes.id
    ]
  }
}
```

### Recipe Guidelines

- Prefer standard, versioned modules (for example, Azure Verified Modules) where available, and pin the version with the `:<tag>` syntax so deployments are reproducible.
- Recipes should be idempotent, meaning they can be run multiple times without causing issues.
- Map developer-authored properties (such as `size`) onto concrete infrastructure settings using `{{context.*}}` parameter expressions rather than exposing platform-specific properties on the Resource Type.
- Map every read-only property of the Resource Type from a module output via the `outputs` field so consumers can connect to the provisioned resource. See [When a module has no output for a property](#when-a-module-has-no-output-for-a-property) for what to do when the module does not expose one.
- Handle secrets securely: mark sensitive properties `x-radius-sensitive: true` on the Resource Type and never log or expose credentials.
- The Kubernetes Recipe Pack should be self-contained (in-cluster, no cloud provider configuration) so it can serve as the zero-config `default-kubernetes/` pack.

### When a module has no output for a property

Each value in `outputs` is the **name of an output the module declares** — not a literal and not a `{{context.*}}` expression, which are resolved only for `parameters`. Two consequences are worth knowing before you add a mapping:

- Naming an output the module does not declare fails validation before the deployment is submitted, so the Recipe cannot be used at all.
- A non-string value such as `port: 3306` is dropped when the Recipe Pack is converted, leaving the property unset with no error at any point.

So a property that a standard module never emits cannot be filled in from `outputs`. When that happens, pick one of these instead of leaving the Resource Type promising a value it will not get:

1. **The value is the same for every Recipe you expect to exist.** Declare the property as an ordinary optional property with a schema `default` instead of `readOnly: true`. Radius materializes the default when the application definition leaves the property unset, and a Recipe that does report the value still overwrites it after deployment. Two things to keep in mind:
   - A `default` on a `readOnly: true` property is ignored, so the property has to be a writable one.
   - Nothing stops an application definition from setting a value the platform will not honor, so the description has to say the value is informational.

   `port` on `Radius.Data/mySqlDatabases`, `Radius.Data/postgreSqlDatabases`, and `Radius.Data/sqlServerDatabases` works this way: the Azure Verified Modules for those services expose no port output, while the services themselves are fixed to the engine's standard port.
2. **The value varies per deployment.** Replace the direct module reference with a Recipe authored in this repository that wraps the module and emits the output itself, under `<Category>/<resourceTypeName>/recipes/<platform>/`. Adding the file is not enough on its own: a Recipe Pack entry resolves its `source` from a registry, so the Recipe also needs to be published as an OCI artifact (see `.github/workflows/publish-bicep-recipes.yaml`) and the pack entry pointed at the published reference.
3. **Neither fits.** Remove the property from the Resource Type. A property the platform cannot populate is worse than an absent one: consumers build connection strings from `CONNECTION_<NAME>_<PROPERTY>` and get a malformed one with no deploy-time error.

Whichever you pick, a Recipe that provisions the resource on something other than the declared default **must** report it as an output. Radius does not detect the mismatch, so the resource would otherwise advertise a value the infrastructure does not use.

## Testing Your Contribution

After creating your Resource Type and Recipes, test them locally using the provided `make` commands.

### Quick Testing Workflow

1. **Set up your environment** (one-time setup):

   ```bash
   make install-radius-cli
   make create-radius-cluster
   ```

2. **Build your Resource Type**:

   ```bash
   make build-resource-type TYPE_FOLDER=Data/redisCaches
   ```

3. **Deploy the Recipe Pack to configure your Environment**:

   A Recipe Pack declares the `Radius.Core/recipePacks` and `Radius.Core/environments` resources, so deploying it registers the Recipes for every Resource Type it covers in the Environment. Add your Resource Type's Recipe to the pack for your target platform, then deploy that pack. For example, the Azure pack (`recipe-packs/azure/aks-recipepack.bicep`) holds the Recipe definitions for all Azure-provisioned types and is deployed with the `rad` CLI, supplying the pack's parameters:

   ```bash
   # Configure the Radius Azure provider credentials (requires AZURE_* env vars:
   # AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, AZURE_LOCATION, AZURE_TENANT_ID, AZURE_CLIENT_ID)
   make configure-azure-provider

   # Deploy the Recipe Pack, supplying its parameters
   rad deploy recipe-packs/azure/aks-recipepack.bicep \
     --parameters azureSubscriptionId=<subscription-id> \
     --parameters azureResourceGroup=<resource-group>
   ```

4. **Deploy the test application**:

   Deploy your Resource Type's test application against the configured Environment:

   ```bash
   rad deploy Data/redisCaches/test/app.bicep
   ```

5. **Run the automated tests**:

  ```bash
  make test
  ```

For detailed testing instructions, see [Testing Resource Types and Recipes](testing-resource-types-recipes.md).

## Integration with CI/CD Testing

Automated test coverage in the repository's CI/CD pipeline is required for Resource Types and their Recipe Packs. The contribution guide with the steps to follow to update the automated tests can be found in [Contributing Tests for Resource Types](contributing-resource-types-tests.md)

## Making a Resource Type a default in Radius

Every Resource Type in this repository can be registered on demand via `rad resource-type create`. A subset are also registered as defaults in Radius, so they are available out of the box without any user action, paired with the zero-config `default-kubernetes/` Recipe Pack. The list of default Resource Types is managed in the [Radius repository](https://github.com/radius-project/radius) via [`deploy/manifest/defaults.yaml`](https://github.com/radius-project/radius/blob/main/deploy/manifest/defaults.yaml).

To make a Resource Type available out of the box as a default:

1. Add the Resource Type manifest to this repository and merge the PR.
2. In the [Radius repository](https://github.com/radius-project/radius), add the Resource Type to [`deploy/manifest/defaults.yaml`](https://github.com/radius-project/radius/blob/main/deploy/manifest/defaults.yaml), run `make update-resource-types`, and create a PR. Once this PR is merged, the type is available and the Bicep extension is published.
