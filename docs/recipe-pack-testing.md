# Plan: CI coverage for committed Recipe Packs (Issue #312)

## Problem

The checked-in Recipe Packs are the files users actually install:
`recipe-packs/kubernetes/default.bicep`, `recipe-packs/azure-aks/azure-aks.bicep`,
`recipe-packs/azure-aci/azure-aci.bicep`. Before this change, CI did not reliably
test these exact files, and testing was built ad hoc per pack rather than as
a reusable framework:

1. **The Kubernetes pack was not built/deployed in CI.** Only its static shape
   was checked (`validate-recipe-packs.sh`). The Azure packs (`azure-aks`,
   `azure-aci`) *were* deployed for real, but via two one-off, hand-written
   workflow steps (PR #316 / #292).
2. **No coverage of "direct-module" mappings** — entries that reference an
   AVM/third-party module directly in the pack, rather than a recipe published
   by this repository. Existing recipe-folder tests did not exercise these
   pack mappings. A wrong AVM parameter name, or a wrong conditional mapping
   (e.g. `tls` → `require_secure_transport`), could pass CI.

**User requirement:** build this as a general framework that works for every
pack we have today (Kubernetes, Azure AKS, Azure ACI) and keeps working when
packs are added later, in both the per-PR and nightly test paths — not three
separate hand-wired test paths.

## The Framework

One shared script, `.github/scripts/lib-recipe-packs.sh`, supplies discovery
helpers for the three testing layers. It answers three questions:

| Function | Answers |
|---|---|
| `rtc_list_recipe_packs` (from `lib-namespaces.sh`) | "What packs exist?" — scans directories under `recipe-packs/` for Bicep files |
| `rtc_recipe_pack_platform_group <pack>` | "What platform does this pack target?" — small lookup table (`kubernetes` → `kubernetes`, `azure-aks`/`azure-aci` → `azure`); every new pack needs a mapping, and a new platform also needs CI jobs |
| `rtc_list_direct_module_types <pack>` | "Which entries reference external modules and have test apps?" — selects sources outside `ghcr.io/radius-project/` when the Resource Type has a `test/app.bicep`; it does not check for a recipe folder |

Each discovered pack must contain exactly one Bicep template. Missing platform
mappings and multiple templates fail the checks. Entries without test apps
are excluded from Layers 2 and 3.

Adding a pack on an existing platform needs a platform mapping, but no new
workflow step. New required pack parameters without defaults need test values
in `rtc_recipe_pack_param_value`. New direct-module entries need test apps
and any checks needed for their behavior.

Three testing layers use these shared helpers:

- **Layer 1 — "does the committed pack still deploy?"**
  New `.github/scripts/deploy-all-checked-in-recipe-packs.sh <platform-group>
  <environment>` finds packs for the requested platform group and
  deploys+associates each one (reusing the existing
  per-template parameter detection from `deploy-checked-in-azure-recipe-pack.sh`,
  generalized). This replaces the two hand-written Azure steps and adds the
  missing Kubernetes step, with one call per platform group:
  - `validate-resource-types.yaml` calls it with `kubernetes` (local k3d, free).
  - `validate-azure-recipes.yaml` calls it with `azure` (real Azure resources,
    already gated by the existing approval flow for forks).
  These calls run in the Bicep jobs, after the build step.
  Deploying a pack does not test each resource mapping inside it.

- **Layer 2 — "are the direct-module property references valid?"** (every PR,
  no cloud cost)
  New `.github/scripts/validate-direct-module-mappings.sh` loops over every
  pack, calls `rtc_list_direct_module_types`, and for each hit:
  1. Collects `{{ ... }}` expressions in that entry's `parameters`/`outputs`.
  2. Confirms each referenced top-level `context.resource.properties.*`
     property is declared in that Resource Type's YAML schema
     (catches typos/renames with zero deployment).
  3. For properties with a declared `enum` (e.g. `tls: [required, optional]`),
     checks that a quoted value compared with `==` is an allowed value.
     Several enum values can share the same else branch.
  It does not evaluate if/else results or validate module parameter names,
  input types, or nested property paths. A reversed `tls` →
  `require_secure_transport` mapping needs a deployment test.
  This runs once, against every pack, regardless of platform. Entries are
  discovered, not hardcoded.

- **Layer 3 — "does the direct-module mapping actually work against real
  infrastructure?"** (nightly and manual runs, real cloud cost)
  New workflow with two fixed jobs: `kubernetes` and `azure`.
  For each platform group: bring up its environment, run Layer 1's deploy
  script, then use `test-all-direct-module-recipes.sh` to activate each pack
  before testing its entries. A type in two packs is tested with each pack.
  For each entry, run
  `.github/scripts/test-direct-module-recipe.sh <resource-type-path>
  <workspace> <environment>` to deploy that type's `test/app.bicep` for
  real and assert success (reusing shared deploy/assert logic refactored out
  of `test-recipe.sh` into a sourced library, so it works without needing a
  `recipes/<platform>/` folder to anchor on).
  MySQL runs with both TLS values and checks the server's
  `require_secure_transport` setting. This catches reversed TLS mappings that
  Layer 2 cannot detect.
  A known pack with no direct-module entries needs no application deployment.
  New entries with test apps are picked up automatically.

## Rollout

The implementation follows these steps:

1. Build `lib-recipe-packs.sh` (discovery + platform-group mapping +
   direct-module detection) and unit-test it directly, before anything else
   depends on it.
2. Build `deploy-all-checked-in-recipe-packs.sh`, wire it into both
   `validate-resource-types.yaml` (kubernetes) and `validate-azure-recipes.yaml`
   (azure), replacing the two hand-written Azure steps.
3. Build `validate-direct-module-mappings.sh` (Layer 2) and wire it into the
   existing cheap/local `validate-release-automation` job.
4. Refactor `test-recipe.sh`'s shared deploy/assert logic into a sourced
   library; build `test-direct-module-recipe.sh` on top of it.
5. Build the nightly workflow (Layer 3), with Kubernetes and Azure jobs, reusing
   steps 2 and 4.
6. Update docs: `recipe-packs/README.md` (how to add a pack / how coverage
   works) and `docs/contributing/testing-resource-types-recipes.md`.
7. Add script-level tests for every new script under `.github/scripts/tests/`,
   matching existing conventions (e.g. `test-validate-recipe-packs.sh`), and
   run them in the PR workflow.

## What's Out of Scope

- Testing every possible property value, including every declared `enum`
  value. Deployment tests use the test app's values, with explicit checks
  for both MySQL TLS values.
- Any new cloud platform support — the framework only covers platform groups
  that already have a CI job (`kubernetes`, `azure`) to plug into.

## Open Questions / Risks

- The Layer 2 check uses text matching for the expression and schema formats
  used in `recipe-packs/**` today. It is not a full expression parser and may
  need changes as new expression shapes are added.
- Nightly Azure tests need `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
  `AZURE_SUBSCRIPTION_ID`, and `TEST_AZURE_OIDC_JSON`, plus Azure trust for the
  GitHub identity of the selected branch. Scheduled runs use the default
  branch; manual runs on other branches need matching trust. Secret presence
  alone does not verify login or a successful deployment.
