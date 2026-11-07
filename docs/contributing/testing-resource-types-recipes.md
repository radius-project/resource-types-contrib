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

If Azure reports `ResourceDeploymentFailure` with `Connection reset by peer`,
the test runner retries the deployment up to three attempts, waiting 10 and 20
seconds before retrying. Retries reuse the same application name and parameters;
cleanup runs only after the final attempt. Other deployment errors, assertion
failures, and cleanup failures still fail the test.

The same retry limit and delays apply when `terraform init` fails to download
a provider package from `releases.hashicorp.com` with `connection reset by peer`.
This includes errors inside a Radius `RecipeDeploymentFailed` JSON response.
Each retry logs the reason and the next attempt number. No other Terraform
download errors qualify. Invalid versions, checksum or signature errors,
authorization errors, and invalid configuration fail without a retry.

Radius returns an initialization failure before it calls Terraform apply.
The runner repeats the same deployment, with the same application name and
parameters, so Radius can reuse resources from earlier work. It does not delete
partially deployed resources between attempts. These rules apply to both
per-recipe and Recipe Pack entry tests.

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

### PostgreSQL Kubernetes transport tests

After publishing the updated Recipe and attaching its Recipe Pack, run:

```bash
.github/scripts/test-recipe.sh Data/postgreSqlDatabases/recipes/kubernetes/bicep
# Switch to the generated Terraform Recipe Pack before running:
.github/scripts/test-recipe.sh Data/postgreSqlDatabases/recipes/kubernetes/terraform
```

Use an isolated Environment/resource group/namespace without an existing `postgresql` Deployment or `postgresql-tls` Secret. Pass the Environment name as the second argument if it is not `default`. The runner tests omitted policy, unchanged redeployment, optional, and explicit required with generated certificates, then repeats with an operator certificate. It checks empty-Secret fallback, encrypted TCP without trust enrollment, explicit public-certificate enrollment for verified identity, operator precedence, connection properties, container restart, and manual rotation. Cleanup deletes test-owned certificates, but application deletion must leave the operator Secret intact. Bicep tests also assert `initSql` execution.

The ordinary Azure test path does not create Kubernetes database certificates. For manual database deployments outside this test runner, follow [PostgreSQL Kubernetes TLS](../../Data/postgreSqlDatabases/README.md#kubernetes-tls).

Partial and malformed operator material must produce a failed/restarting certificate init container, a certificate-specific diagnostic, and no ready replicas in a fresh deployment. Tests verify the current Deployment generation and ReplicaSet/Pod ownership; a Pending Pod, image-pull error, or timeout is not certificate-failure evidence. Production retains the normal rollout/provider deadlines. The runner observes failures while deployment is in flight, repairs the test Secret, replaces only the failed Pod to reset backoff, and waits for the original operation to settle before cleanup or any recovery redeploy. It does not require `ProgressDeadlineExceeded` or a prompt Terraform CLI failure. Bicep reports resource submission rather than workload readiness, so its CLI success is never the readiness assertion.

The fixture target also requires Python 3 and OpenSSL. It executes the certificate-preparation scripts extracted from both Recipes and checks their parity, generated certificates, RSA/EC operator keys, malformed inputs, and private-key permissions. Release-candidate runs with pinned sources that predate the lifecycle script retain the legacy application test and explicitly report that transport coverage is unavailable.

Both drivers also test a failed update from a healthy `optional` database to requested `required` policy after corrupting the same operator Secret in place. The new Pod must fail certificate initialization while the original ready Pod remains the only ready Service endpoint. Service-addressed plaintext and verified-TLS SQL queries check both `pg_stat_ssl` and `inet_server_addr()` to attribute traffic to that old Pod, with UID, restart-count, readiness, and EndpointSlice checks around each query. The test reselects a ready client and copies its public CA before each probe because Bicep can replace the client during the failed update. It repairs the Secret, settles the original apply before any explicit `required` recovery deployment, and requires a healthy required-policy rollout with the old Pod removed. This bounded observation does not prove indefinite availability or live IPv6 connectivity.

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

## Azure PostgreSQL pack-test capacity

The nightly and release-candidate Azure pack tests select a PostgreSQL region
before they create the main resource group or configure the Azure provider.
The release-candidate workflow keeps the released source and pack pins. A pack
mapping that does not match the test tuple fails the PostgreSQL check.
For older release pins whose PostgreSQL test app fixes `size: 'S'`, the workflow
creates a temporary parameterized test harness outside the checkout. The harness
lets the selected `S` or `M` reach the deployment without changing the pinned
resource type, recipe, pack, or test app. Unsupported test-app shapes fail before
deployment rather than silently testing the wrong size.

### Candidate settings and order

Set repository variable `RTC_AZURE_TEST_REGIONS` to a comma-separated list of
approved regions. It overrides all other region settings. If it is not set,
the workflows use `AZURE_LOCATION` (default `westus3`), then
`AZURE_FALLBACK_LOCATION` (default `eastus2`), then `centralus`. The automatic
default list is `westus3,eastus2,centralus`; it avoids `westus2` because the
unrelated `azure-aks` AI models test requires an OpenAI model deployment that is
not listed for that region in Microsoft's
[Global Standard Americas availability table](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure-region-availability).
These two legacy settings are also repository variables. Scripts accept the same
names as environment variables. The selector's `RTC_AZURE_TEST_REGIONS` takes
precedence over positional regions.

Duplicates are removed without changing order. At most four distinct regions
are allowed. An explicit one-region list prevents selection in another region.
The default produces three regions x two sizes, or six candidate tuples. Before
use, verify **all candidates**, including automatic defaults, for subscription
access, quota, policy, PostgreSQL 16, and the other `azure-aks` pack services.
Check the exact OpenAI model and version, especially if explicitly adding
`westus2`. The defaults are candidates, not a claim that every subscription can
use them.

Repository variable `RTC_POSTGRES_TEST_SIZES` defaults to `S,M`. Only `S` and
`M` are allowed; duplicates are removed. `S` maps to `Standard_B1ms`/`Burstable`;
`M` maps to `Standard_D2ds_v5`/`GeneralPurpose`. Try the first size in every
region before trying the next size. Thus the default order is all three `S`
candidates, then all three `M` candidates. Empty or malformed script settings,
unsafe region values, and excessive lists fail before Azure calls.

Probes use PostgreSQL 16, 32 GiB storage, no HA, no geo-redundant backup,
automatic zone placement, password and Entra authentication, and public
networking without a firewall rule. They do not disable TLS. The pack's public
size contract and production defaults do not change.

### Workflow, recovery, and cleanup

The nightly and release-candidate callers first create deterministic main and
probe group names plus one 128-bit owner token. They then call
`.github/workflows/azure-postgres-preflight.yaml` as a reusable job. The job
returns typed status, location, size, SKU, tier, probe group, and sanitized
attempt records.

The preflight creates every candidate server in the exact disposable probe
group. It does not delete servers individually. It deletes the complete group
after selection and confirms deletion. GNU `timeout` bounds Azure CLI commands,
but stopping the CLI does not cancel the provider request. A late server create
therefore remains inside the owned probe group. The existing unconditional
cleanup job independently retries deletion after the caller jobs finish.

`capacity_exhausted`, `unsupported`, and `restricted` are candidate outcomes.
The selector continues when it receives them. A mixture of unsupported and
restricted candidates reports `catalog_unavailable`, not capacity exhaustion.
Malformed catalog data, authentication or configuration failures, command
timeouts, and unconfirmed group cleanup report `probe_error` and stop the Azure
test path. Safe no-selection results allow unrelated Azure tests to continue,
but the PostgreSQL phase is skipped and reported as failed.

The preflight job has a 65-minute limit: 45 minutes for candidate work, up to
15 minutes for group deletion, and five minutes for job setup and reporting.
The main Azure test job keeps its 330-minute limit. After a successful
selection, the caller gives the real
PostgreSQL deployment and same-region recovery a fresh 45-minute deadline. If
the real deployment returns only a structured capacity error, cleanup succeeds,
and Azure inventory confirms that no new resources remain, the entry runner can
retry once with the other approved size in the same region. It does not retry
other failures and never changes region after the main group exists.

The sanitized preflight record is uploaded as a workflow artifact and rendered
as a job-summary table. It contains no credentials or raw provider messages.
More candidates can improve reliability, but a successful probe does not
reserve capacity for deployment.

For example, after checking access and service support for `centralus`, constrain
the next nightly run to that region and test the existing `M` mapping first:

```bash
gh variable set RTC_AZURE_TEST_REGIONS --body centralus
gh variable set RTC_POSTGRES_TEST_SIZES --body M,S
gh workflow run nightly-recipe-pack-tests.yaml -f version=edge
```

These are persistent repository settings. Restore or remove them after the run
if they were only for diagnosis. Inspect the summary and diagnostics rather than
treating a probe as a passing deployment test.

Offline fixtures need Bash, Node.js, `jq`, and GNU `timeout`:

```bash
make test-recipe-pack-entries-unit
```

## Azure CLI login renewal in CI

Azure validation, nightly tests, and release candidate tests install
`azure-cli-with-refresh.sh` after `azure/login`. The wrapper requests a fresh
GitHub OIDC assertion and logs in again before an Azure CLI call when the last
login is at least four minutes old. A file lock prevents concurrent callers
from renewing the same login at once. It also sets the test subscription.
This covers capacity probes, lock checks, cleanup, and diagnostic child
processes throughout a long test step, not just between workflow steps.

The five-minute GitHub assertion is not an Azure access token. Cached access
tokens can work for about an hour, then fail when Azure CLI tries to exchange
the expired assertion. Renewing only at job start does not prevent that error.
The wrapper fails the command if renewal fails. It does not retry deployments
or change Radius pods' separate Azure workload identity.

## Azure lock inventory diagnostics

Recipe Pack entry tests compare Azure management locks before and after each
deployment with the lock IDs in the test application's Radius inventory.
A new, test-owned lock must be deleted before Radius application cleanup.
A lock ID recorded by Radius but absent from Azure is an inventory error,
not proof that the test identity lacks `Microsoft.Authorization/locks/delete`.
The test still fails and skips application deletion in that case.

On either lock failure, the test saves `locks.json` with the application name,
the two Azure lock lists, and the Radius lock ID list. It does not save raw
Radius resource properties or secrets. Download
`azure-test-diagnostics-nightly-azure` or `azure-test-diagnostics-rc-azure`.
Set `RTC_AZURE_DIAGNOSTICS_DIR` for local collection.

Nightly and release candidate pod-log artifacts also include
`deployment-engine.log`, alongside Dynamic RP logs that record the resource
IDs returned by the Deployment Engine. These logs help identify conditional
resources that the engine skipped but still returned as output resources.
If no Deployment Engine pod is found, the file states that explicitly.

## Test failure diagnostics

Validation, nightly tests, and release candidate tests save diagnostics **before** they delete
a failed test app. Resource type and application name do not control whether logs
are collected. This applies to Azure, Kubernetes, and other platforms, for both
per-recipe tests and checked-in Recipe Pack tests. Deployment, assertion, and
cleanup failures all trigger collection. Cleanup-only failures trigger collection
after the failed cleanup attempt.
The collector does not retry a deployment or turn a failed test into a pass.
Successful attempts do not trigger collection. Failed attempts keep their logs
even if a later PostgreSQL capacity-recovery attempt succeeds. The validation, nightly, and release candidate
runtime jobs also collect a workflow-level snapshot after any failed step. This
includes build, setup, pack deployment, and PostgreSQL preflight failures that occur
before a test app deploys. Steps with `continue-on-error` are checked by their
original outcome, so they cannot suppress collection. PostgreSQL selection details
remain in `postgres-selection.json`.

Download `azure-test-diagnostics-bicep` from Azure validation, or
`azure-test-diagnostics-nightly-azure` from the nightly run. Each failure has a
separate directory with `azure.json` and `collector-status.txt`. There is no
artifact when no test attempt or workflow stage fails. Azure Terraform validation uses
`azure-test-diagnostics-terraform`.
Release candidate tests use `azure-test-diagnostics-rc-azure`.
Kubernetes validation uses `test-diagnostics-bicep` or `test-diagnostics-terraform`.
The nightly and release candidate Kubernetes artifacts are
`test-diagnostics-nightly-kubernetes` and `test-diagnostics-rc-kubernetes`.
Non-Azure snapshots contain `radius.json` rather than `azure.json`.

Runtime jobs set `RTC_TEST_DIAGNOSTICS_DIR` to their artifact directory.
`RTC_AZURE_DIAGNOSTICS_DIR` remains a fallback for older workflows and local
commands. An explicit empty `RTC_TEST_DIAGNOSTICS_DIR` disables collection.
If neither variable is set, local runs do not collect diagnostics.
Azure context is optional for Radius logs: missing credentials, a missing resource
group, or a failed Azure account lookup cannot prevent cluster log collection.
Azure API reads run only with a valid Azure subscription and resource group.

In GitHub Actions, the Azure container test limits `rad deploy` to 15 minutes
and `rad app delete` to 3 minutes after a deployment or assertion failure,
with a further 5-second kill limit for each. App cleanup after a successful
test has no timeout.
This leaves time to collect evidence when provisioning stalls, instead of
waiting for the 30-minute job limit. A timeout remains a test failure.
Collection runs before app cleanup, and Kubernetes cleanup is still attempted.
The nightly and release candidate test steps also pass their absolute deadline
as `RTC_AZURE_TEST_STEP_DEADLINE_EPOCH`. Each Azure deployment must stop at least
six minutes before that deadline, or eighteen minutes for PostgreSQL capacity recovery
to preserve its twelve-minute application deletion budget and cleanup verification.
Assertions use the time left before the same
cutoff; they cannot use the diagnostics and cleanup reserve. Container tests retain their shorter
15-minute limit. PostgreSQL tests retain their shorter recovery deadline.
Other failure cleanup uses a three-minute application deletion limit and bounded
Kubernetes deletion requests. PostgreSQL recovery waits for Kubernetes cleanup
and blocks recovery if deletion fails. A test cannot start a deployment after the
reserved part of the step budget begins. This lets a stalled MongoDB deployment
reach the collector instead of waiting for the workflow to terminate the step.
These limits do not apply to local runs or non-Azure tests.
They do not cancel an Azure operation or fix the cause of a provider
stall; the workflow still performs its final resource-group cleanup.

The JSON file contains an allowlist of resource IDs, provisioning states,
container image references, container states, event names/counts/timestamps,
subnet and NAT links, and Activity Log operation/status/correlation/request IDs
when Azure returns them. This is a snapshot of the test's dedicated resource
group, not proof that every resource belongs to the failed app. It includes
NGroups, container group profiles, standard container groups, VNets, NAT
gateways, load balancers, and public IP resource states.

For every Azure failure, the collector saves a resource-group inventory and
OpenAI account, model deployment, Cosmos DB account, MongoDB database, and
PostgreSQL server states. Activity Log records also include structured error
codes, but not provider error messages. These provider-specific reads add detail;
they are not an application or resource-type filter.

The `radiusLogs` field contains filtered records from the deployment engine,
Dynamic RP, Applications RP, and UCP pods, including each discovered replica.
The collector reads these before Azure resource API calls and failed-test cleanup.
Records include timestamps, trace/span IDs,
logger names, operation names, recipe references, terminal-state markers, HTTP phases and methods, request
hosts/paths, response status codes, and elapsed times when the component emits
them. Image references and image IDs identify the running component builds.
Request queries, headers, bodies, and free-text log messages are not saved.
Each pod log read has at most 2,000 records and a 512 KiB limit.
`tailOnly` and `omitted` identify a bounded, filtered snapshot, not a complete log.
Log rotation or a pod restart can remove earlier records before collection.
Workflow snapshots use a six-hour lookback to include setup and preflight activity.
Their collection limits remain the same as per-test snapshots. If setup failed
before the cluster was ready, the report records the failed collection attempt
instead of claiming that logs are complete.

For an OpenAI provisioning conflict, compare account and model-deployment
Activity Log timestamps and statuses, then use trace IDs and request paths to
find the matching engine and Radius records. A successful account operation
followed by a rejected child operation differs from a child request sent while
account creation is still running. These records help locate the fault; they
do not assume that Bicep, the engine, Radius, or Azure is responsible.

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

Azure resource collection uses only GET requests, scoped to the configured
subscription and test resource group. For local runs without
`AZURE_SUBSCRIPTION_ID`, the collector first reads the selected account ID with
`az account show --query id`. It does not list accounts or read credentials.
That lookup uses the same time and request budget.
Each request has a 10-second limit and a 2 MiB response
limit. Each collection has a shared 90-second budget and at most 24 Azure and Kubernetes requests.
The shell stops the collector after 100 seconds, with a further 5-second kill
limit. Only the first page and at most 20 items per list are kept; pagination
URLs are never followed. Partial results are saved after each request.
`errors`, `truncations`, and `collector-status.txt` report failed API calls,
invalid responses, and bounds. Missing permissions and unsupported APIs produce
a failed-call entry with the CLI exit code. Raw provider errors are withheld
to prevent secret exposure, so the artifact cannot distinguish those two causes.

For local tests, set `RTC_TEST_DIAGNOSTICS_DIR` to an output directory.
For Azure provider data, also set `AZURE_RESOURCE_GROUP` to the dedicated test group. Set
`AZURE_SUBSCRIPTION_ID` to use a subscription other than the selected account's.
The per-recipe runner derives the platform from the recipe path. The pack test
driver derives it from `PLATFORM_GROUP`; for a direct invocation of
`test-recipe-pack-entry.sh`, also set `RTC_TEST_PLATFORM=azure`.
Collection requires Node.js, kubectl, and GNU `timeout`. Azure provider data also
requires Azure CLI with an existing login.
It does not change permissions. In CI, its Azure CLI calls use the same login
renewal wrapper as the tests. Missing tools are reported and cleanup still runs.

Offline checks require Node.js, Bash, `jq`, and GNU `timeout`; no Azure login is needed:

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
