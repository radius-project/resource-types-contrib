# Recipe Packs

A **Recipe Pack** is a manifest of recipes by Resource Type referenced in a Radius Environment. Each pack is a directory under `recipe-packs/` containing:

- a `.bicep` file named after the pack (for example `azure-aks.bicep`; the default Kubernetes pack is `default.bicep`): declares only a `Radius.Core/recipePacks` resource whose `recipes` map has an entry per Resource Type. Pack files never create or modify Environments; associate a deployed pack with an Environment using `rad env update --recipe-packs`.
- `README.md`: documents the pack, its parameters, and the recipes it includes.

## Available Recipe Packs

| Pack | Directory | Container platform | Other resource types |
| --- | --- | --- | --- |
| Kubernetes (default) | [`kubernetes/`](kubernetes/) | Kubernetes | Kubernetes |
| Azure AKS | [`azure-aks/`](azure-aks/) | Kubernetes | Azure managed services |
| Azure ACI | [`azure-aci/`](azure-aci/) | Azure Container Instances | Azure Files and Key Vault only |
| AWS EKS | [`aws-eks/`](aws-eks/) | Kubernetes (Amazon EKS) | AWS managed services (Amazon RDS for MySQL today) |

## The default Recipe Pack

`rad init` installs the **Kubernetes Recipe Pack** ([`kubernetes/default.bicep`](kubernetes/default.bicep)) as the `default` pack (it embeds its own copy, kept in sync with this file), so a fresh Radius installation needs no extra configuration.

## How to create a new Recipe Pack

1. **Create the folder and files.** Add `recipe-packs/<pack-name>/` with a `.bicep` file and a `README.md`. Use a folder name that identifies the platform and, where a cloud offers more than one compute target, the compute runtime (for example `azure-aks`, `azure-aci`, `kubernetes`). Name the Bicep file after the pack (for example `azure-aci.bicep`).
2. **Declare the pack.** In the Bicep file, declare a single `Radius.Core/recipePacks` resource and nothing else (`make validate-recipe-packs` enforces this) whose `recipes` map has an entry keyed by each Resource Type (for example `Radius.Data/redisCaches`).
3. **Wire each Recipe.** Point each entry at its module `source` and map `parameters` (using `{{context.*}}` expressions) and `outputs`. Reuse published modules such as Azure Verified Modules where possible, and reference in-repo Bicep recipes by their published OCI image.
4. **Publish any in-repo Bicep recipes** the pack references by adding them to [`.github/workflows/publish-bicep-recipes.yaml`](../.github/workflows/publish-bicep-recipes.yaml) so the `source` images exist.
5. **Enable releases.** Add the new folder name to the `recipe_pack` choice list in [`.github/workflows/release-recipe-pack.yaml`](../.github/workflows/release-recipe-pack.yaml). Packs are otherwise discovered automatically: any folder under `recipe-packs/` that holds at least one `.bicep` file is treated as a releasable pack. Before tagging, the release checks that every OCI Recipe `source` in the pack can be pulled anonymously, so a new registry's packages must be public and its referenced tags published first. `latest` is only created when **Publish Bicep Recipes** runs with a stable `release_version`.
6. **Document it.** Give the pack a `README.md` following the existing packs, listing its parameters and the Recipes it wires.

For guidance on authoring the Recipes themselves, see [Contributing Resource Types and Radius Recipes](../docs/contributing/contributing-resource-types-recipes.md#recipes-and-recipe-packs).

## How Recipe Packs are tested in CI

CI uses [`.github/scripts/lib-recipe-packs.sh`](../.github/scripts/lib-recipe-packs.sh)
to find pack files and direct-module entries. Each pack directory must contain
one Bicep template and have a platform mapping in that library. Missing mappings
and multiple templates fail the checks.

| Layer | What it checks | When it runs | Cost |
| --- | --- | --- | --- |
| 1. Deploy the pack | Each committed pack file deploys and attaches to an Environment without error | Every PR | Free (Kubernetes); real cloud resources (Azure) |
| 2. Validate direct-module mappings | Referenced Radius properties exist in the schema; string literals compared with enum properties are declared enum values | Every PR | Free (static check, no deployment) |
| 3. Test pack entries | Build repository recipes from the checkout, activate each pack, deploy its entries' `test/app.bicep`, check results, and clean up | Nightly and manual dispatch | Real cloud resources (Azure) |

A "direct-module" entry has a module source outside `ghcr.io/radius-project/`
and a `test/app.bicep` in its Resource Type directory. Sources within that
prefix are treated as repository-owned recipes. Nightly tests cover these
recipes both on their own and through the checked-in packs. Entries without
test apps fail layer 3 unless explicitly excluded; issue #398 tracks the
temporary `containerImages` exclusion.

Nightly pack deployment sets `RECIPE_PACK_USE_LOCAL_RECIPES=true`. It builds
each repository-owned Bicep recipe from the checked-out commit and uses a
temporary copy of the pack with local registry sources and `plainHttp: true`.
The copy retains the pack name, parameters, output mappings, and external
module versions, including AVM versions. Azure packs also build the
Kubernetes recipes they reference. Missing or ambiguous recipe sources and
build failures stop the test; there is no fallback to a published artifact.
The checked-in files are not changed.

Local preparation requires each entry's `source` to be a nonempty,
single-quoted literal on its own line, indented two spaces below the entry key.
Variables, interpolation, missing or duplicate sources, and inline entries fail
before deployment. Nested parameter fields named `source` are not recipe sources.

The static check does not validate target module parameter names, parameter
shapes, or the meaning of conditional results. Several enum values can share
a default branch. The nightly deployment checks the values used by each test
app, not every possible property value. A type used by two packs is tested
once per pack, with that pack active.

Azure has no API that reports live regional capacity. Before the nightly
deploys an Azure PostgreSQL pack entry, it runs
[`probe-azure-postgres-capacity.sh`](../.github/scripts/probe-azure-postgres-capacity.sh).
The probe creates and deletes a `Standard_B1ms` (Burstable) flexible server in
the test resource group. It retries only on `SkuNotAvailable` or `ServerIsBusy`
(`RTC_POSTGRES_PROBE_ATTEMPTS`, default 3; `RTC_POSTGRES_PROBE_WAIT_SECONDS`,
default 600). If capacity stays unavailable, the entry fails with an Azure
capacity error and the entry is not deployed. After a successful create, the
probe waits for the delete (`RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS`,
default 900), so the probe does not hold capacity that the entry needs. If
that delete fails, the preflight fails. The probe uses `AZURE_SUBSCRIPTION_ID`
when it is set, and the Azure CLI default subscription otherwise. Keep the
probe SKU in sync with the size `S` mapping in the `azure-aks` pack.

Before the nightly creates its Azure resource group,
[`select-azure-test-location.sh`](../.github/scripts/select-azure-test-location.sh)
runs one probe in the preferred region (`AZURE_LOCATION` repository variable,
default `westus3`) and, if it has no capacity, one in the fallback region
(`AZURE_FALLBACK_LOCATION`, default `eastus2`). All Azure tests then use the
first region with capacity. If neither region has capacity, the preferred
region is used.

MySQL pack entries that map `tls` to `require_secure_transport` run both
`tls: required` and `tls: optional`. They pass `verifyTransport` through
`test/verify-transport.parameters.json` because Radius CLI `name=value`
arguments are strings, not Booleans. The client readiness probe reads
`@@GLOBAL.require_secure_transport` from the deployed server and requires `1`
or `0`, respectively. CI waits for that probe before it reports success.
Reversed mappings fail even when a database connection succeeds. Pack entries
that do not enforce transport policy, such as the Kubernetes MySQL recipe, use
the connection-only probe.

### Testing a Radius release candidate

[`release-candidate-recipe-pack-tests.yaml`](../.github/workflows/release-candidate-recipe-pack-tests.yaml)
runs the same tests as the nightly workflow, but against what a Radius release
candidate ships instead of `main`. Start it manually with the Radius version
(for example, `0.62.0-rc1`). It reads `deploy/manifest/defaults.yaml` from that
Radius tag and runs
[`prepare-release-candidate-sources.sh`](../.github/scripts/release/prepare-release-candidate-sources.sh),
which:

- restores every pinned namespace folder and Recipe Pack folder from its pinned
  commit, and removes namespaces and packs that the release does not pin;
- changes each `ghcr.io/radius-project/...` Recipe source in those packs to the
  pinned namespace commit SHA. A released `rad` uses the same tag, and
  `publish-bicep-recipes.yaml` publishes it.

The workflow checks that every pack source can be pulled, installs that Radius
version, and runs the nightly steps unchanged. It supports only releases whose
pinned packs all have a platform mapping in `lib-recipe-packs.sh`; older
releases that pin a pack without one are not supported.

### What to do when you add or change a pack

- **New pack, same platform group (`kubernetes` or `azure`):** map the folder
  name in `rtc_recipe_pack_platform_group` in `lib-recipe-packs.sh`. No new
  test script or workflow step is needed.
- **New platform (for example, AWS):** add the platform mapping and a CI job for that
  platform group following the existing `kubernetes`/`azure` jobs as a
  template (see [`validate-resource-types.yaml`](../.github/workflows/validate-resource-types.yaml),
  [`validate-azure-recipes.yaml`](../.github/workflows/validate-azure-recipes.yaml),
  [`nightly-recipe-pack-tests.yaml`](../.github/workflows/nightly-recipe-pack-tests.yaml),
  and [`release-candidate-recipe-pack-tests.yaml`](../.github/workflows/release-candidate-recipe-pack-tests.yaml)).
  The `aws` group has Layer 1 only: `validate-resource-types.yaml` deploys and
  activates the AWS packs on the local cluster, which needs no AWS account.
  Layers 2 and 3 need an AWS account in CI.
- **New direct-module entry in an existing pack:** add a `test/app.bicep`
  under that Resource Type's folder (see
  [Testing Resource Types and Recipes](../docs/contributing/testing-resource-types-recipes.md)
  for the expected shape). Without it, Layer 3 fails the entry.
- **New required pack parameter:** add a test value to
  `rtc_recipe_pack_param_value` in `lib-recipe-packs.sh`.

### Running these checks locally

On Windows, run these Bash scripts in Git Bash, not PowerShell or Command
Prompt. Keep `.sh` files with LF line endings. The `make` commands below
require a separate Make installation. To run the static mapping check
without Make, use `bash .github/scripts/validate-direct-module-mappings.sh`.

```bash
# After cluster setup, build types and extension configuration
RECIPE_PLATFORM_FILTER=kubernetes make build

# Layer 1: deploy every checked-in pack for a platform group.
# The optional third argument is a Radius group, not an Azure resource group.
.github/scripts/deploy-all-checked-in-recipe-packs.sh kubernetes default

# Before layer 3, use the current checkout rather than published repository recipes.
RECIPE_PACK_USE_LOCAL_RECIPES=true \
  .github/scripts/deploy-all-checked-in-recipe-packs.sh kubernetes default

# Layer 2: static check of every direct-module mapping (no cluster needed)
make validate-direct-module-mappings

# Layer 3: real deployment test of every repository recipe and every
# non-excluded entry in every checked-in pack. The entry command requires all
# packs for the group to be deployed and activates each in turn. Issue #398
# tracks the temporary containerImages skip.
make test-recipe-pack-entries PLATFORM_GROUP=kubernetes WORKSPACE=default ENVIRONMENT=default

# Test the shared library and test drivers without cloud resources (requires jq)
make test-recipe-pack-entries-unit
```

Use a dedicated test environment. The scripts replace its active pack list
and delete test applications. Kubernetes cleanup selects only resources with
the test application's `radapp.io/application` label.

The nightly Azure job uses the same repository secrets as the PR Azure job:
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, and
`TEST_AZURE_OIDC_JSON`. Azure must also trust the GitHub OIDC subject for the
selected branch. Scheduled runs use the default branch; manual runs on other
branches need matching trust. Secret presence alone does not verify login.
