# Radius Resource Types & Recipes — Agent Instructions

This repository contains Radius **Resource Type definitions** (YAML schemas) and **Recipes** (Bicep / Terraform templates) for deploying those resources on AWS, Azure, and Kubernetes.

For deeper background, see:
- [Contributing Guide](../docs/contributing/contributing-resource-types-recipes.md)
- [Testing Guide](../docs/contributing/testing-resource-types-recipes.md)
- [Radius Documentation](https://docs.radapp.io)
- [Recipes Overview](https://docs.radapp.io/guides/recipes/overview/) 
- [Recipe Context Schema](https://docs.radapp.io/reference/context-schema/)

## Repository Layout

```
<Category>/                           # e.g., Data/, Security/, Compute/
└── <resourceTypeName>/               # camelCase, plural (e.g., redisCaches/)
    ├── <resourceTypeName>.yaml       # Resource Type definition
    ├── README.md                     # Platform engineer documentation
    ├── recipes/
    │   └── <platform-service>/       # e.g., kubernetes/, aws-memorydb/, azure-cache/
    │       ├── bicep/*.bicep
    │       └── terraform/{main.tf, var.tf}
    └── test/app.bicep                # Test application (used for automated recipe tests)
```

## Resource Type Definitions

### Naming
- **Namespace**: `Radius.<Category>` (e.g., `Radius.Data`)
- **Type names**: camelCase, plural (e.g., `redisCaches`, `sqlDatabases`)
- **Property names**: camelCase
- **API Version**: `YYYY-MM-DD-preview` (e.g., `2025-08-01-preview`)

### Schema Rules
- `environment` is always required
- `application` is required for resources that must belong to an application
- Read-only properties (set by recipe after deployment) must have `readOnly: true`
- Every property description is prefixed with `(Required)`, `(Optional)`, or `(Read Only)`
- Top-level `description` must include Bicep usage examples in fenced code blocks
- Avoid unquoted YAML special characters: `: { } [ ] , & * # ? | - < > = ! % @ \`

```yaml
namespace: Radius.<Category>
types:
  <resourceTypeName>:
    description: |
      ...
    apiVersions:
      'YYYY-MM-DD-preview':
        schema:
          type: object
          properties:
            environment:
              type: string
              description: (Required) The Radius Environment ID...
          required:
            - environment
```

## Recipes — General

- Each recipe is either a `.bicep` file **or** `main.tf` + `var.tf`
- Must accept the Radius `context` parameter/variable
- Must be idempotent
- Must handle secrets securely (never log or expose)
- Must include all read-only properties in the output
- Output a `result` object:

```bicep
// Bicep
output result object = {
  resources: [...]      // UCP resource IDs for cleanup
  values: {  host: '...', port: ... }
  secrets: { password: '...' }
}
```

```hcl
# Terraform
output "result" {
  value = {
    resources = [...]
    values    = { ... }
    secrets   = { ... }
  }
  # Add `sensitive = true` only when `result` includes secret material.
}
```

## Bicep Recipe Gotchas

These are non-obvious failures caught during recipe development. Apply them when writing or debugging Bicep recipes.

### Use `.?` safe navigation for optional context paths

ARM validates property paths at compile time, **before** evaluating `??`. Plain access to a possibly-absent property fails with `InvalidTemplate` at deploy time even with a `?? {}` fallback.

```bicep
// Wrong — InvalidTemplate at deploy time
var connections = context.resource.connections ?? {}

// Correct
var connections = context.resource.?connections ?? {}
```

Apply `.?` to any optional path: `resourceProperties.?connections`, `resourceProperties.?extensions.?daprSidecar`, etc.

### Azure tag names cannot contain `/`

Tags like `radapp.io/application` fail with `InvalidTagNameCharacters`. Use `-`:

```bicep
tags: { 'radapp.io-application': appName }   // not 'radapp.io/application'
```

### Azure resource ID properties require fully qualified IDs

Properties like `managedEnvironmentId` need `/subscriptions/...` paths. Passing a bare name raises `LinkedInvalidPropertyId`. Accept the **name** as the recipe parameter and construct the ID with `resourceId()`:

```bicep
param containerAppsEnvironmentName string
...
managedEnvironmentId: resourceId('Microsoft.App/managedEnvironments', containerAppsEnvironmentName)
```

### `location` must be a deploy-time constant

You cannot assign `existingResource.location` to a new resource's `location` (raises `BCP120`). Expose a parameter instead, and don't assume `resourceGroup().location` matches the location of referenced resources:

```bicep
param containerAppsLocation string = resourceGroup().location
```

### Parameter design

- Use **descriptive, scoped names**: `containerAppsEnvironmentName`, not `envName`. Recipe parameters are passed via `recipeParameters` alongside other types — names must be unambiguous.
- Prefer **names over resource IDs** when the recipe can build the ID itself.
- Provide sensible defaults where possible.
- Add `@description()` to all parameters.

### Connection env vars

When a resource has `connections`, generate `CONNECTION_<NAME>_<PROPERTY>` environment variables. Exclude internal properties (`recipe`, `status`, `provisioningState`, `resourceProvisioning`). Respect per-connection `disableDefaultEnvVars`.

## Testing & Publishing

```bash
# Setup
make install-radius-cli
make create-radius-cluster

# Build — only build resource types that aren't already registered.
# Check first with `rad resource-type list` and skip the build step if
# `Radius.<Category>/<resourceTypeName>` already appears in the output.
rad resource-type list
make build-resource-type TYPE_FOLDER=<Category>/<resourceType>   # only if not listed above
make build-bicep-recipe RECIPE_PATH=<Category>/<resourceType>/recipes/<platform>/bicep
make build-terraform-recipe RECIPE_PATH=<Category>/<resourceType>/recipes/<platform>/terraform

# Register before testing
make register RECIPE_TYPE=bicep
make register RECIPE_TYPE=terraform ENVIRONMENT=my-terraform-env

# Test
make test-recipe RECIPE_PATH=<Category>/<resourceType>/recipes/<platform>/bicep
make test

# Cleanup
make delete-radius-cluster
```

For Bicep recipes, **validate by publishing** rather than `az bicep build` — `rad bicep publish` uses the bicep version bundled with Radius (`~/.rad/bin/bicep`), which is what runs at deploy time:

```bash
rad bicep publish --file <recipe>.bicep --target br:<registry>/<path>:<tag>
rad deploy <app>.bicep -w <workspace>
```

Pay attention to `BCP318` (null safety) and `BCP120` (deploy-time constant) warnings — they often indicate runtime failures even when the build succeeds.

### `test/app.bicep` template

Required for CI:

```bicep
extension radius
extension <resourceTypeName>

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'testapp'
  properties: { environment: environment }
}

resource myResource 'Radius.<Category>/<resourceTypeName>@YYYY-MM-DD-preview' = {
  name: 'testresource'
  properties: {
    environment: environment
    application: app.id
    // ... required properties
  }
}
```

## Contribution Checklist

- [ ] Follows folder structure and naming conventions
- [ ] Namespace is `Radius.<Category>`; type name camelCase + plural
- [ ] API version `YYYY-MM-DD-preview`
- [ ] `environment` in required properties
- [ ] All properties have `(Required)`/`(Optional)`/`(Read Only)` prefixed descriptions
- [ ] Top-level `description` includes Bicep examples
- [ ] Read-only properties marked `readOnly: true`
- [ ] Recipe outputs all read-only properties; idempotent; handles secrets safely
- [ ] `test/app.bicep` exists
- [ ] `make test-recipe` passes locally

## Maturity Levels

- **Alpha** — basic validation, single recipe, manual testing
- **Beta** — multi-platform recipes (AWS / Azure / Kubernetes), Bicep + Terraform, automated tests
- **Stable** — 100% test coverage, CI/CD integration, maintainer ownership
