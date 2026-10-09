# Recipe Pack testing

## Purpose

Test the Recipe Pack files stored in this repository, not only packs generated
for tests. This document describes the implementation in this PR, not a report
of successful cloud test runs.

A Radius **Resource Type** defines the properties an application can request,
such as a database size. A **recipe** creates the resources needed to meet that
request. A **Recipe Pack** lists recipes and maps Radius properties to their
inputs and outputs. A Radius **Environment** selects the packs applications use.

The tests cover the Kubernetes, Azure AKS, and Azure ACI packs. They use three
layers because deploying a pack does not prove that each recipe in it works.

## Test layers

| Layer | What it checks | When it runs |
| --- | --- | --- |
| 1. Deploy the pack | Each stored pack deploys and can be selected by an Environment | PR Bicep jobs and nightly jobs |
| 2. Check mappings without deployment | Referenced Radius properties exist; compared enum values are allowed by the schema | PR checks |
| 3. Deploy test applications | Selected module entries can deploy their test apps and pass the checks below | Daily at 09:00 UTC and manual runs |

Layer 2 needs no cluster or cloud resources. Layers 1 and 3 use a local
Kubernetes cluster; their Azure jobs also use real Azure resources and incur
cloud costs. Existing tests for individual repository recipes remain in place.

### 1. Deploy each stored pack

`deploy-all-checked-in-recipe-packs.sh` finds the packs for a platform group,
deploys each Bicep file, and selects that pack on the Environment. It supplies
test values for required parameters that have no default.

The Bicep jobs in `validate-resource-types.yaml` and
`validate-azure-recipes.yaml` call this script after the build step. The old
Azure deployment entry point remains available because `pull_request_target`
runs the base branch's workflow during the transition.

This layer checks pack deployment and selection only. It does not deploy each
resource listed in the pack or prove its input and output mappings are correct.

### 2. Check property references and allowed values

`validate-direct-module-mappings.sh` reads selected pack entries and the
Resource Type's YAML schema. It checks references such as
`context.resource.properties.tls` inside `{{ ... }}` expressions.

The check fails if the top-level property does not exist. For a property with
an `enum` (a list of allowed values), it also checks comparisons in the form
`context.resource.properties.tls == "optional"`. The quoted value must be in
that list. Several values can share the same else branch.

The script uses text matching for the formats used in this repository. It is
not a full Bicep or expression parser. It does not check module parameter
names, nested property paths, input types, or the result of an if/else
expression. In particular, it cannot detect a mapping that swaps `ON` and
`OFF`. Deployment tests must check the resulting behavior.

### 3. Deploy applications with each pack active

`nightly-direct-module-recipe-tests.yaml` has two fixed jobs: Kubernetes and
Azure. It does not generate jobs from the list of platform groups.

Each job prepares its environment and deploys its packs. Then
`test-all-direct-module-recipes.sh` selects each pack before testing its
entries. A Resource Type present in two packs is tested with each pack.
A known pack with no selected entries needs no application deployment.

`test-direct-module-recipe.sh` deploys the Resource Type's `test/app.bicep`.
It uses the same deployment, result-check, and cleanup code as the existing
recipe tests in `lib-recipe-test.sh`.

| Resource Type | Additional check in the shared runner |
| --- | --- |
| MySQL | Run the direct-module test with both `tls: required` and `tls: optional`. The client reads `@@GLOBAL.require_secure_transport` from the server and expects `1` or `0`, respectively. The runner waits for the client deployment to become available. |
| PostgreSQL | Require a nonempty host, a numeric port, database `appdb`, and no `secrets` field in the returned properties. |
| Containers | Require two container resources to return distinct, nonempty hosts. |
| Other types | Require successful test-app deployment; there is no extra result check in the shared runner. Coverage depends on the test app. |

The MySQL server-setting check applies to direct-module tests. Existing
per-recipe MySQL tests keep their connection-only check. The other shared
checks run when their Resource Type is selected by either test path.

## How entries are selected

The shared library, `.github/scripts/lib-recipe-packs.sh`, finds pack
directories and maps each to `kubernetes` or `azure`. Each discovered pack
must have exactly one Bicep template and a platform mapping.

Layers 2 and 3 select an entry when its module source is outside
`ghcr.io/radius-project/` and its Resource Type has a `test/app.bicep`.
These are called **direct-module entries** in the scripts. Entries with that
source prefix are treated as repository recipes and use the existing recipe
test path. Selection does not depend on whether a recipe folder exists.
Entries without a test app are excluded from both layers.

## Failures and cleanup

Unknown platform groups, missing pack mappings, multiple pack templates, and
required parameters without test values cause errors. A failed pack selection
stops the run so tests cannot use the previous pack by mistake. An application
test failure is counted, and the driver continues with the remaining entries.
The driver returns failure if any application test failed.

Test templates must accept `applicationName` and use it for the application
resource name. The runner passes the same generated name to deployment,
result checks, and deletion. If a template declares `password`, the runner
generates a test password.

The runner attempts cleanup after a deployment or result-check failure.
It deletes the test application, then leftover Kubernetes secrets, deployments,
and services with that application's `radapp.io/application` label.
Cleanup errors also fail the test. The Azure job has a final resource cleanup
step, and both nightly jobs collect Radius pod logs.

Use a dedicated test environment: pack selection replaces its active pack
list, and the scripts do not restore the previous list.

## Maintaining coverage

| Change | Required test setup |
| --- | --- |
| New pack on Kubernetes or Azure | Add its folder name to `rtc_recipe_pack_platform_group` in `.github/scripts/lib-recipe-packs.sh`. |
| New platform | Add a platform mapping and PR/nightly jobs that prepare and test that platform. |
| New direct-module entry | Add a compatible `test/app.bicep` and checks for the behavior that matters. |
| New required pack parameter without a default | Add a test value to `rtc_recipe_pack_param_value` in `.github/scripts/lib-recipe-packs.sh`. |

The PR workflow also runs script tests with small sample repositories and
simulated commands. They check discovery, deployment arguments, invalid
property references, invalid enum comparisons, pack selection, result checks,
and cleanup failures. They do not replace live deployment tests.

## Limits and operating requirements

These tests do not cover every allowed property value or every module setting.
Except for the explicit MySQL cases, deployment coverage uses the values in
each test app. Passing static checks does not prove that a module accepts the
mapped parameters or that the resulting service works.

The nightly Azure job requires `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`, and `TEST_AZURE_OIDC_JSON`. Azure must trust the
GitHub identity for the branch used by the run. Scheduled runs use the default
branch; manual runs on another branch need matching trust. The presence of
secrets alone does not prove that login works.

For commands and setup, see [Recipe Pack testing in CI](../recipe-packs/README.md#how-recipe-packs-are-tested-in-ci)
and [Testing Resource Types and Recipes](contributing/testing-resource-types-recipes.md).
