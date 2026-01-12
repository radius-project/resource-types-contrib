# Testing Resource Types and Recipes

This guide explains how to test Resource Types and Recipes locally using the standardized `make` commands provided in this repository.

## Prerequisites

Before testing, ensure you have:

- Docker installed (for running k3d)
- `k3d` installed
- `kubectl` installed
- `helm` installed
- `oras` installed
- `make` available in your environment

## Quick Start

### 1. Set Up Your Environment

Create a local Kubernetes cluster with Radius (and Dapr) installed:

```bash
# Install Radius CLI (optional: specify version with RAD_VERSION=0.48.0)
make install-radius-cli

# Create k3d cluster with Radius and Dapr configured
make create-radius-cluster
```

> The `make create-radius-cluster` target provisions Dapr in the cluster so recipes that depend on the Dapr sidecar work out of the box.

### 2. Build Your Resource Type

Build and validate a Resource Type definition:

```bash
make build-resource-type TYPE_FOLDER=Data/mySqlDatabases
```

This command:
- Creates the Resource Type in Radius using `rad resource-type create`
- Generates a Bicep extension file (`.tgz`)
- Updates `bicepconfig.json` to reference the extension
- Enables IntelliSense and validation in your Bicep files

### 3. Build Your Recipes

#### Bicep Recipe

```bash
make build-bicep-recipe RECIPE_PATH=Data/mySqlDatabases/recipes/kubernetes/bicep
```

This publishes the Bicep recipe to a local OCI registry.

#### Terraform Recipe

```bash
make build-terraform-recipe RECIPE_PATH=Security/secrets/recipes/kubernetes/terraform
```

This packages the Terraform module and publishes it to an in-cluster HTTP server.

### 4. Test Individual Recipes

Test a recipe by registering it and deploying a test application:

```bash
# Test a Bicep recipe
make test-recipe RECIPE_PATH=Data/mySqlDatabases/recipes/kubernetes/bicep

# Test a Terraform recipe
make test-recipe RECIPE_PATH=Security/secrets/recipes/kubernetes/terraform
```

The `test-recipe` command:
- Auto-detects whether the recipe is Bicep or Terraform
- Registers the recipe as the default for its resource type
- Deploys the `test/app.bicep` file (if it exists)
- Cleans up resources after testing

### 5. Test All Recipes

Run tests for all recipes in the repository:

```bash
make test
```

This discovers and tests every recipe automatically.

To run only Bicep or Terraform recipes, set the `RECIPE_TYPE` variable. You can also override the environment name with `ENVIRONMENT` if you created an isolated Radius environment for testing:

```bash
# Test only Bicep recipes
make test RECIPE_TYPE=bicep

# Test Terraform recipes in a custom environment
make test RECIPE_TYPE=terraform ENVIRONMENT=my-terraform-env
```

## Build All Resources

Build all resource types and recipes at once:

```bash
make build
```

## Utility Commands

List available resource types:

```bash
make list-resource-types
```

List all recipes (Bicep and Terraform):

```bash
make list-recipes
```

## Creating Test Applications

For recipes to be tested via `make test-recipe` or `make test`, create a `test/app.bicep` file in your Resource Type directory:

```
Data/mySqlDatabases/
├── mySqlDatabases.yaml
├── README.md
├── recipes/
│   └── kubernetes/
│       ├── bicep/
│       │   └── kubernetes-mysql.bicep
│       └── terraform/
│           └── main.tf
└── test/
    └── app.bicep  # Test application
```

Example `test/app.bicep`:

```bicep
extension radius
extension mySqlDatabases

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'testapp'
  properties: {
    environment: environment
  }
}

resource mysql 'Radius.Data/mySqlDatabases@2025-08-01-preview' = {
  name: 'mysql'
  properties: {
    environment: environment
    application: app.id
  }
}
```

## Cleanup

Delete your test cluster when done:

```bash
make delete-radius-cluster
```

## Manual Testing (Advanced)

If you prefer manual testing or need to test externally-published recipes:

### Register a Recipe Manually

**Bicep Recipe:**

```bash
rad recipe register default \
  --environment default \
  --resource-type "Radius.Data/mySqlDatabases" \
  --template-kind bicep \
  --template-path "reciperegistry:5000/recipes/mysql/kubernetes:latest" \
  --plain-http
```

**Terraform Recipe:**

```bash
rad recipe register default \
  --environment default \
  --resource-type "Radius.Security/secrets" \
  --template-kind terraform \
  --template-path "http://tf-module-server.radius-test-tf-module-server.svc.cluster.local/secrets-kubernetes.zip"
```

### Deploy and Test

```bash
rad deploy test/app.bicep -p environment=default
```

### Cleanup

```bash
rad app delete testapp --yes
rad recipe unregister default --resource-type "Radius.Data/mySqlDatabases"
```

## Common Workflows

### Complete Workflow for a New Resource Type

```bash
# 1. Create directory structure
mkdir -p Data/newResource/recipes/kubernetes/{bicep,terraform}
mkdir -p Data/newResource/test

# 2. Create and edit resource type definition
# Edit Data/newResource/newResource.yaml

# 3. Build and validate the resource type
make build-resource-type TYPE_FOLDER=Data/newResource

# 4. Create recipes (Bicep or Terraform)
# Edit Data/newResource/recipes/kubernetes/bicep/*.bicep

# 5. Build the recipe
make build-bicep-recipe RECIPE_PATH=Data/newResource/recipes/kubernetes/bicep

# 6. Create test application
# Edit Data/newResource/test/app.bicep

# 7. Test the recipe
make test-recipe RECIPE_PATH=Data/newResource/recipes/kubernetes/bicep

# 8. Test all recipes (if you have multiple)
make test
```

### Testing an Existing Resource Type

```bash
# Test all recipes in the repository
make test

# Test a specific recipe
make test-recipe RECIPE_PATH=Security/secrets/recipes/kubernetes/bicep
```

### Available Make Commands

```bash
# Environment setup
make install-radius-cli          # Install Radius CLI
make create-radius-cluster       # Create k3d cluster with Radius
make delete-radius-cluster       # Delete test cluster

# Build commands
make build                                              # Build all resources
make build-resource-type TYPE_FOLDER=<path>            # Build single resource type
make build-bicep-recipe RECIPE_PATH=<path>             # Build Bicep recipe
make build-terraform-recipe RECIPE_PATH=<path>         # Build Terraform recipe

# Test commands
make test                          # Test all recipes
make test-recipe RECIPE_PATH=<path>  # Test single recipe

# Utility commands
make list-resource-types           # List resource type folders
make list-recipes                  # List all recipes
make help                          # Show all available commands
```

## Troubleshooting

### "Error: kubectl not found"

Install kubectl by following the [official installation guide](https://kubernetes.io/docs/tasks/tools/).

### "Error: cluster not found" or cluster connection issues

Create a new cluster:
```bash
make create-radius-cluster
```

Verify cluster is running:
```bash
kubectl cluster-info
rad env list --preview
```

### Recipe not found during testing

Ensure you've built the recipe first:
```bash
make build-bicep-recipe RECIPE_PATH=<path>
# or
make build-terraform-recipe RECIPE_PATH=<path>
```

### Bicep extension not recognized

Make sure `bicepconfig.json` is updated:
```bash
make build-resource-type TYPE_FOLDER=<folder>
```

### Recipe registration fails

Ensure the recipe is built before testing:
- **Bicep**: `make build-bicep-recipe RECIPE_PATH=<path>`
- **Terraform**: `make build-terraform-recipe RECIPE_PATH=<path>`

## Maturity Level Testing Requirements

- **Alpha**: Manual testing using `make test-recipe` is sufficient
- **Beta**: Automated testing with `test/app.bicep` files required for all recipes
- **Stable**: Full CI/CD integration (see [Contributing Tests](contributing-resource-types-tests.md))
