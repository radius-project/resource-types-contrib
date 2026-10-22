# Testing Resource Types and Recipes

This guide explains how to test Resource Types and Recipes locally using the standardized `make` commands provided in this repository.

## Prerequisites

Before testing, ensure you have:

- Docker installed (for running kind)
- `kubectl` installed
- `helm` installed
- `oras` installed
- `jq` installed (also required by the Recipe Pack unit tests)
- `make` available in your environment

## Quick Start

### 1. Set Up Your Environment

Create a local Kubernetes cluster with Radius (and Dapr) installed:

```bash
# Install Radius CLI (optional: specify version with RAD_VERSION=0.48.0)
make install-radius-cli

# Create kind cluster with Radius configured
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

### 4. Add Your Recipes to a Recipe Pack

The Environment gets its Recipes from a Recipe Pack. Generate a pack from the
recipes you built, deploy it, and attach it to the Environment. The pack name
sets the recipe kind: a name that contains `terraform` selects Terraform
recipes. All other names select Bicep recipes.

```bash
# Bicep recipes
RECIPE_PLATFORM_FILTER=kubernetes make generate-recipe-pack PACK_NAME=biceprecipepack OUTPUT_FILE=recipe-pack-bicep.bicep
make deploy-recipe-pack BICEP_FILE=recipe-pack-bicep.bicep
make update-env-recipe-pack RECIPE_PACK_NAME=biceprecipepack

# Terraform recipes
RECIPE_PLATFORM_FILTER=kubernetes make generate-recipe-pack PACK_NAME=terraformrecipepack OUTPUT_FILE=recipe-pack-terraform.bicep
make deploy-recipe-pack BICEP_FILE=recipe-pack-terraform.bicep
make update-env-recipe-pack RECIPE_PACK_NAME=terraformrecipepack
```

Attach the pack for the recipe kind that you want to test before you run the
tests. Always set `RECIPE_PLATFORM_FILTER` to one platform (for example,
`kubernetes`). Without the filter, the generator includes the recipes for all
platforms. The pack then has duplicate resource type keys and does not compile.

### 5. Test Individual Recipes

Deploy a test application with the recipe from the active Recipe Pack:

```bash
# Test a Bicep recipe
make test-recipe RECIPE_PATH=Data/mySqlDatabases/recipes/kubernetes/bicep

# Test a Terraform recipe
make test-recipe RECIPE_PATH=Security/secrets/recipes/kubernetes/terraform
```

The `test-recipe` command:
- Auto-detects whether the recipe is Bicep or Terraform
- Uses the recipe from the Recipe Pack on the Environment
- Deploys the `test/app.bicep` file (if it exists)
- Cleans up resources after testing

### 6. Test All Recipes

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
param applicationName string = 'testapp'

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: applicationName
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

All test apps must declare `applicationName` and use it for the application
resource name. The test runner passes the generated name to both the template
and the CLI, then uses that name for assertions and cleanup. Keep the default
name for manual use. Other required credentials must use a secure `password`
parameter; the runner generates its value. Usernames can have a test default.

Delete your test cluster when done:

```bash
make delete-radius-cluster
```

## Azure container failure diagnostics

Azure validation and nightly Azure tests save diagnostics **before** they delete
a failed `Radius.Compute/containers` test app. This applies to deployment and
assertion failures, for both per-recipe tests and checked-in Recipe Pack tests.
The collector does not retry a deployment or change the test result or cleanup.
It does not run for successful tests, other resource types, or non-Azure tests.

Download `azure-test-diagnostics-bicep` from Azure validation, or
`azure-test-diagnostics-nightly-azure` from the nightly run. Each failure has a
separate directory with `azure.json` and `collector-status.txt`. There is no
artifact when no applicable test fails. A Terraform artifact uses the suffix
`-terraform` if a future Azure container Terraform test fails.

The JSON file contains an allowlist of resource IDs, provisioning states,
container image references, container states, event names/counts/timestamps,
subnet and NAT links, and Activity Log operation/status/correlation/request IDs
when Azure returns them. This is a snapshot of the test's dedicated resource
group, not proof that every resource belongs to the failed app. It includes
NGroups, container group profiles, standard container groups, VNets, NAT
gateways, load balancers, and public IP resource states.

The `2024-11-01-preview` API has no NGroups child-list endpoint or NGroup
instance view. Standard container-group reads can return instance-view events,
but might not expose NGroups-managed children. The collector reports empty
collections and missing instance views. Activity Log records can arrive late.
Their absence does not prove that an operation did not occur. Direct provider
operations do not require an Azure ARM deployment record.

The collector does **not** save raw resource JSON, CLI stderr, free-text event
messages, detailed status text, container commands or logs, environment values,
tags, credentials, or deployment parameters/outputs. It does not enable CLI
debug output. Thus original PUT/poll response headers, registry HTTP responses,
and free-text image-pull detail remain unavailable. Use the saved resource IDs,
timestamps, and correlation IDs for a provider investigation. These diagnostics
do not establish or fix the cause of a registry failure.

Collection uses only GET requests, scoped to the configured subscription and
test resource group. Each request has a 10-second limit and a 2 MiB response
limit. Each collection has a 90-second request budget and at most 24 requests.
The shell stops the collector after 100 seconds, with a further 5-second kill
limit. Only the first page and at most 20 items per list are kept; pagination
URLs are never followed. Partial results are saved after each request.
`errors`, `truncations`, and `collector-status.txt` report failed API calls,
invalid responses, and bounds. Missing permissions and unsupported APIs produce
a failed-call entry with the CLI exit code. Raw provider errors are withheld
to prevent secret exposure, so the artifact cannot distinguish those two causes.

For local Azure tests, set `RTC_AZURE_DIAGNOSTICS_DIR`, `AZURE_SUBSCRIPTION_ID`,
and `AZURE_RESOURCE_GROUP` to an output directory and the dedicated test scope.
The per-recipe runner derives the platform from the recipe path. The pack test
driver derives it from `PLATFORM_GROUP`; for a direct invocation of
`test-recipe-pack-entry.sh`, also set `RTC_TEST_PLATFORM=azure`.
Collection requires Node.js, Azure CLI with an existing login, and GNU `timeout`.
It does not change login or permissions. Missing tools are reported and cleanup
still runs.

Offline checks require Node.js, Bash, and `jq`; no Azure login is needed:

```bash
node --test .github/scripts/tests/test-azure-test-diagnostics.js
bash .github/scripts/tests/test-azure-diagnostics-integration.sh
make test-recipe-pack-entries-unit
```

The focused checks cover allowed fields, secret exclusion, read-only scope,
API errors, time and size limits, collection before cleanup, unchanged failure
status, and unchanged non-Azure behavior. Run them repeatedly to check the
diagnostic code; this does not measure or validate an ACI flake fix.

## Manual Testing (Advanced)

If you prefer manual testing or need to test externally-published recipes:

### Add a Recipe to a Recipe Pack Manually

Write a Recipe Pack that points to your recipe. Use this for a recipe that is
published outside the test cluster.

**Bicep Recipe:**

```bicep
extension radius

resource mypack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'mypack'
  location: 'global'
  properties: {
    recipes: {
      'Radius.Data/mySqlDatabases': {
        kind: 'bicep'
        source: 'reciperegistry:5000/recipes/mysql/kubernetes:latest'
        plainHttp: true
      }
    }
  }
}
```

**Terraform Recipe:**

```bicep
extension radius

resource mypack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'mypack'
  location: 'global'
  properties: {
    recipes: {
      'Radius.Security/secrets': {
        kind: 'terraform'
        source: 'http://tf-module-server.radius-test-tf-module-server.svc.cluster.local/secrets-kubernetes.zip'
      }
    }
  }
}
```

Deploy the pack and attach it to the Environment:

```bash
make deploy-recipe-pack BICEP_FILE=mypack.bicep
make update-env-recipe-pack RECIPE_PACK_NAME=mypack
```

### Deploy and Test

```bash
rad deploy test/app.bicep -p environment=default
```

### Cleanup

```bash
rad app delete testapp --yes
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

# 7. Add the recipes to a Recipe Pack and attach it to the Environment
RECIPE_PLATFORM_FILTER=kubernetes make generate-recipe-pack PACK_NAME=biceprecipepack OUTPUT_FILE=recipe-pack-bicep.bicep
make deploy-recipe-pack BICEP_FILE=recipe-pack-bicep.bicep
make update-env-recipe-pack RECIPE_PACK_NAME=biceprecipepack

# 8. Test the recipe
make test-recipe RECIPE_PATH=Data/newResource/recipes/kubernetes/bicep

# 9. Test all recipes (if you have multiple)
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
make create-radius-cluster       # Create kind cluster with Radius
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
rad env list
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

### Recipe Pack deployment fails

Ensure the recipe is built before you generate and deploy the Recipe Pack:
- **Bicep**: `make build-bicep-recipe RECIPE_PATH=<path>`
- **Terraform**: `make build-terraform-recipe RECIPE_PATH=<path>`

## Testing Recipe Packs

Recipe Packs (`recipe-packs/*/*.bicep`) are tested separately from individual
Recipes. See [Recipe Packs: How Recipe Packs are tested in CI](../../recipe-packs/README.md#how-recipe-packs-are-tested-in-ci)
for the three layers of checks (deploy, static mapping validation, and nightly
real-deployment tests) and the `make` targets for running them locally.

Run the checks that do not require a cluster before submitting a pack change:

```bash
make validate-recipe-packs
make validate-direct-module-mappings
make test-recipe-pack-entries-unit
```

Nightly tests first generate Bicep and Terraform packs and run every repository
recipe for the selected platform. They then activate each checked-in pack
before testing every entry that has a `test/app.bicep`. Entries without a test
application fail unless they are explicitly excluded. The current temporary
exclusion is `containerImages`; issue #398 tracks its enablement. A pack with
no runnable entries also fails. The tests use the values in each Resource
Type's test app; they do not test every enum value.

See [Recipe Pack source selection and format rules](../../recipe-packs/README.md#how-recipe-packs-are-tested-in-ci)
for how nightly uses checkout-built recipes and which source declarations it accepts.

To run the same pack tests locally after cluster and resource type setup:

```bash
RECIPE_PACK_USE_LOCAL_RECIPES=true \
  .github/scripts/deploy-all-checked-in-recipe-packs.sh azure default
make test-recipe-pack-entries PLATFORM_GROUP=azure WORKSPACE=default ENVIRONMENT=default
```

The static check validates Radius property references and enum comparison
literals, not the target module's parameter contract.

## Maturity Level Testing Requirements

- **Alpha**: Manual testing using `make test-recipe` is sufficient
- **Beta**: Automated testing with `test/app.bicep` files required for all recipes
- **Stable**: Full CI/CD integration (see [Contributing Tests](contributing-resource-types-tests.md))

## Testing Azure Recipes

Azure recipes require additional setup since they deploy resources to Azure.

### Prerequisites for Azure Recipes

Before testing Azure recipes, ensure you have:

- Azure CLI installed and authenticated (`az login`)
- An Azure subscription with appropriate permissions (Contributor role recommended)
- A service principal for Radius to use when deploying Azure resources

### Local Testing

#### 1. Create a Service Principal

Radius needs a service principal to deploy Azure resources. Create one with the Azure CLI:

```bash
az ad sp create-for-rbac --name "radius-test-sp" --role Contributor --scopes /subscriptions/<your-subscription-id>
```

This outputs credentials you'll need:
```json
{
  "appId": "<client-id>",
  "displayName": "radius-test-sp",
  "password": "<client-secret>",
  "tenant": "<tenant-id>"
}
```

#### 2. Set Up Azure Environment Variables

Export the required environment variables for Azure authentication and resource configuration:

```bash
# Azure authentication (from service principal output)
export AZURE_CLIENT_ID="<appId from above>"
export AZURE_CLIENT_SECRET="<password from above>"
export AZURE_TENANT_ID="<tenant from above>"
export AZURE_SUBSCRIPTION_ID="<your-subscription-id>"

# Azure resource configuration
export AZURE_LOCATION="westus3"  # or your preferred region
export AZURE_RESOURCE_GROUP="rrttest-local"  # unique name for testing
```

#### 3. Create an Azure Resource Group

```bash
az group create \
  --name "$AZURE_RESOURCE_GROUP" \
  --location "$AZURE_LOCATION" \
  --subscription "$AZURE_SUBSCRIPTION_ID"
```

#### 4. Create a Radius Cluster with Azure Provider

Azure recipes use **Azure Workload Identity** for authentication, which requires OIDC configuration. When `AZURE_TENANT_ID` is set, the cluster setup script automatically configures the KinD cluster with OIDC support and installs the Azure Workload Identity webhook.

Follow the [Azure Workload Identity documentation for self-managed clusters](https://azure.github.io/azure-workload-identity/docs/installation/self-managed-clusters.html) to set up OIDC.

Once OIDC is configured, set the `TEST_AZURE_OIDC_JSON` environment variable with your OIDC configuration:

```bash
export TEST_AZURE_OIDC_JSON='{
  "AZURE_OIDC_ISSUER": "https://your-oidc-issuer-url",
  "AZURE_OIDC_ISSUER_PUBLIC_KEY": "<base64-encoded-public-key>",
  "AZURE_OIDC_ISSUER_PRIVATE_KEY": "<base64-encoded-private-key>"
}'
```

**Create the cluster:**

```bash
# Install Radius CLI
make install-radius-cli

# Create kind cluster with OIDC support and Radius installed
# AZURE_TENANT_ID triggers OIDC/Workload Identity setup
make create-radius-cluster

# Configure the Azure cloud provider on the Environment created by cluster setup
AZURE_ENVIRONMENT_NAME=default make configure-azure-provider
```

#### 5. Build and Test Azure Recipes

```bash
# Build all Azure recipes
make build-azure-recipes

# Add Azure Bicep recipes to a Recipe Pack and attach it
RECIPE_PLATFORM_FILTER=azure make generate-recipe-pack PACK_NAME=azurebiceprecipepack OUTPUT_FILE=recipe-pack-azure-bicep.bicep
make deploy-recipe-pack BICEP_FILE=recipe-pack-azure-bicep.bicep
make update-env-recipe-pack RECIPE_PACK_NAME=azurebiceprecipepack ENVIRONMENT=default

# Test Azure Bicep recipes
RECIPE_PLATFORM_FILTER=azure make test ENVIRONMENT=default RECIPE_TYPE=bicep

# Add Azure Terraform recipes to a Recipe Pack and attach it
RECIPE_PLATFORM_FILTER=azure make generate-recipe-pack PACK_NAME=azureterraformrecipepack OUTPUT_FILE=recipe-pack-azure-terraform.bicep
make deploy-recipe-pack BICEP_FILE=recipe-pack-azure-terraform.bicep
make update-env-recipe-pack RECIPE_PACK_NAME=azureterraformrecipepack ENVIRONMENT=default

# Test Azure Terraform recipes
RECIPE_PLATFORM_FILTER=azure make test ENVIRONMENT=default RECIPE_TYPE=terraform
```

#### 6. Cleanup

```bash
# Clean up Azure resources created by recipes
make cleanup-azure-resources

# Delete the resource group
az group delete --name "$AZURE_RESOURCE_GROUP" --yes --no-wait

# Delete the local Kubernetes cluster
make delete-radius-cluster
```

### Required Environment Variables Reference

| Variable | Description | Example |
|----------|-------------|---------|
| `AZURE_CLIENT_ID` | Service principal application (client) ID | `12345678-1234-1234-1234-123456789012` |
| `AZURE_CLIENT_SECRET` | Service principal password/secret | `your-secret-value` |
| `AZURE_TENANT_ID` | Azure AD tenant ID | `12345678-1234-1234-1234-123456789012` |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID | `12345678-1234-1234-1234-123456789012` |
| `AZURE_LOCATION` | Azure region for resources | `westus3`, `eastus`, `westeurope` |
| `AZURE_RESOURCE_GROUP` | Resource group name for test resources | `rrttest-local` |

### Azure Recipe Directory Structure

Azure recipes should follow this structure:

```
Data/mySqlDatabases/
├── mySqlDatabases.yaml
├── README.md
├── recipes/
│   ├── azure/
│   │   ├── bicep/
│   │   │   └── azure-mysql.bicep
│   │   └── terraform/
│   │       ├── main.tf
│   │       └── var.tf
│   └── kubernetes/
│       └── ...
└── test/
    └── app.bicep
```

### Troubleshooting Azure Recipe Tests

#### "ResourceGroupNotFound" Error

Ensure the resource group exists before running tests:
```bash
az group show --name "$AZURE_RESOURCE_GROUP"
```

If it doesn't exist, create it:
```bash
az group create --name "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION"
```

#### Azure Authentication Fails

Verify your environment variables are set correctly:
```bash
echo "Client ID: $AZURE_CLIENT_ID"
echo "Tenant ID: $AZURE_TENANT_ID"
echo "Subscription ID: $AZURE_SUBSCRIPTION_ID"
```

Test authentication with the Azure CLI:
```bash
az login --service-principal \
  --username "$AZURE_CLIENT_ID" \
  --password "$AZURE_CLIENT_SECRET" \
  --tenant "$AZURE_TENANT_ID"
```

#### Service Principal Permission Issues

Ensure your service principal has `Contributor` role on the subscription or resource group:
```bash
az role assignment create \
  --assignee "$AZURE_CLIENT_ID" \
  --role Contributor \
  --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID"
```

#### Recipe Deployment Timeout

Azure resource provisioning can take longer than Kubernetes. If deployments time out:
- Check the Azure portal for deployment status
- Review Radius pod logs 
- Some Azure resources (e.g., databases) may take 10-20 minutes to provision
