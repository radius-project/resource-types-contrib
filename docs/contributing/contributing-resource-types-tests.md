# Contributing Tests for Stable Resource Types

Resource Types at the Stable maturity level are required to integrate with Radius CI/CD testing. This guide explains how to add automated test coverage for your Resource Type so it can be validated in CI/CD pipelines.

## Overview

The repository provides a complete testing framework built around `make` commands. The same commands used for local development are also used in CI/CD, ensuring consistent behavior.

### Testing Architecture

```
Repository Root
├── Makefile                    # Main entry point for commands
├── .github/
│   ├── build/                  # Make target definitions
│   │   ├── help.mk            # Help documentation
│   │   ├── environment.mk     # Environment setup targets
│   │   └── test.mk            # Testing targets
│   ├── scripts/               # Shell scripts for testing
│   │   ├── build-all.sh       # Build all resources
│   │   ├── build-resource-type.sh
│   │   ├── build-bicep-recipe.sh
│   │   ├── build-terraform-recipe.sh
│   │   ├── test-recipe.sh     # Test individual recipes
│   │   └── test-all-recipes.sh
│   └── workflows/             # GitHub Actions workflows
└── <Category>/<ResourceType>/
    ├── <resourceType>.yaml    # Resource Type definition
    ├── recipes/               # Recipe implementations
    └── test/
        └── app.bicep          # Test application (required for CI)
```

## Available Make Commands

### Environment Setup

```bash
make install-radius-cli          # Install Radius CLI
make create-radius-cluster       # Create k3d cluster with Radius
make clean                       # Delete cluster, config, and build artifacts
```

### Building

```bash
make build                                              # Build all resources
make build-resource-type TYPE_FOLDER=<path>            # Build single resource type
make build-bicep-recipe RECIPE_PATH=<path>             # Build Bicep recipe
make build-terraform-recipe RECIPE_PATH=<path>         # Build Terraform recipe
```

### Testing

```bash
make test                          # Test all recipes
make test-recipe RECIPE_PATH=<path>  # Test single recipe
make list-resource-types           # List resource type folders
make list-recipes                  # List all recipes
```

## Using the Dev Container

This repository includes a pre-configured dev container with all necessary tools installed, making it easy to get started with development and testing.

### Opening the Dev Container

1. Ensure you have VS Code with the Dev Containers extension installed
2. Open the repository in VS Code
3. When prompted, click "Reopen in Container" (or use Command Palette: "Dev Containers: Reopen in Container")
4. Wait for the container to build and initialize

The dev container includes:
- Radius CLI (latest version)
- Azure CLI
- Terraform
- k3d (Kubernetes in Docker)
- kubectl
- Bicep
- All required VS Code extensions

### Running Tests in the Dev Container

Once inside the dev container, you can use all the standard make commands:

```bash
# Install Radius
make install-radius-cli

# Set up your test environment
make create-radius-cluster

# Build and test
make build
make test
```

### Troubleshooting: Connection Refused Error

If you encounter a "Connection refused" error on `localhost:5000` while building or testing recipes, this indicates that the local registry isn't accessible. To fix this:

1. Open a terminal in the dev container
2. Run the following command:
   ```bash
   socat TCP-LISTEN:5000,reuseaddr,fork TCP:host.docker.internal:5000
   ```
3. Keep this terminal running in the background
4. In a new terminal, retry your build or test command

This creates a port forward that allows the container to access the OCI registry running on your host machine. The registry is created when you run `make create-radius-cluster`, which uses the k3d option to set up a local registry at `localhost:5000`, which is accessible from within the cluster as `reciperegistry:5000`. See the script [`.github/scripts/create-cluster.sh`](../../.github/scripts/create-cluster.sh) for more details on how the `make create-radius-cluster` command sets up the registry.

**Note**: You may need to run this `socat` command each time you start the dev container if the connection issue persists.

## Adding Automated Test Coverage

Follow these steps to ensure your Resource Type is tested in CI/CD pipelines.

### Step 1: Create Test Application

Create a `test/app.bicep` file in your Resource Type directory:

```
<Category>/<ResourceType>/
├── <resourceType>.yaml
├── README.md
├── recipes/
│   └── ...
└── test/
    └── app.bicep    # ← Create this file
```

**Example: Security/secrets/test/app.bicep**

```bicep
extension radius
extension secrets

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'testapp'
  properties: {
    environment: environment
  }
}

resource secret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'secret'
  properties: {
    environment: environment
    application: app.id
    data: {
      apikey: {
        value: 'abc123xyz'
      }
    }
  }
}
```

**Key Requirements:**
- Extension name must match your resource type name (e.g., `secrets` for `Radius.Security/secrets`)
- Include `environment` parameter (set by test framework)
- Create an Application resource
- Create your Resource Type resource with required properties

### Step 2: Test Locally

Before submitting to CI, test your application locally:

```bash
# Create test cluster
make create-radius-cluster

# Build your resource type
make build-resource-type TYPE_FOLDER=Security/secrets

# Build recipes
make build-bicep-recipe RECIPE_PATH=Security/secrets/recipes/kubernetes/bicep

# Test the recipe (deploys test/app.bicep)
make test-recipe RECIPE_PATH=Security/secrets/recipes/kubernetes/bicep
```

### Step 3: Verify CI/CD Integration

When you submit your PR, the CI workflow will:

1. Set up a test Kubernetes cluster
2. Install Radius
3. Build all resource types (including yours)
4. Build all recipes (Bicep and Terraform)
5. Test each recipe by:
   - Registering it as the default
   - Deploying your `test/app.bicep`
   - Verifying successful deployment
   - Cleaning up resources

You can see these steps by running:

```bash
make test
```

## Testing Multiple Recipes

If your Resource Type has multiple recipes, the test framework will automatically test each one:

```
Data/redisCaches/
├── redisCaches.yaml
├── recipes/
│   ├── kubernetes/
│   │   ├── bicep/
│   │   │   └── kubernetes-redis.bicep     # Tested automatically
│   │   └── terraform/
│   │       └── main.tf                    # Tested automatically
│   └── azure-cache/
│       ├── bicep/
│       │   └── azure-redis.bicep          # Tested automatically
│       └── terraform/
│           └── main.tf                    # Tested automatically
└── test/
    └── app.bicep                          # Used for all recipe tests
```

Each recipe is tested independently using the same `test/app.bicep` file.

## Troubleshooting

### Test application won't deploy

- Verify your `test/app.bicep` syntax locally
- Ensure extension name matches resource type name
- Check that all required properties are set

### Resource type not found in CI

- Confirm your resource type is in a configured category folder
- Check that `<resourceType>.yaml` is valid YAML
- Ensure the folder structure matches the expected pattern

### Recipe registration fails

- Verify recipe files exist in expected locations
- For Bicep: Ensure `.bicep` files are valid
- For Terraform: Ensure `main.tf` exists

### Local tests pass but CI fails

- Ensure your test doesn't depend on local files outside the resource type directory
- Check that all dependencies are properly declared in the recipe
- Review CI logs for specific error messages

## Best Practices

1. **Keep tests simple**: Test one resource type instance with minimal configuration
2. **Test required properties**: Ensure your test exercises all required properties
3. **Clean naming**: Use consistent, descriptive names for resources
4. **Document special cases**: Add comments for non-obvious test configurations
5. **Test early**: Run `make test-recipe` frequently during development