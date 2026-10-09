# Plan: CI coverage for committed Recipe Packs (Issue #312)

## Problem

The checked-in Recipe Packs are the files users actually install:
`recipe-packs/kubernetes/default.bicep`, `recipe-packs/azure-aks/azure-aks.bicep`,
`recipe-packs/azure-aci/azure-aci.bicep`. CI does not reliably test these exact
files, and today's testing is built ad hoc per pack rather than as a reusable
framework:

1. **The Kubernetes pack is never built/deployed in CI.** Only its static shape
   is checked (`validate-recipe-packs.sh`). The Azure packs (`azure-aks`,
   `azure-aci`) *are* deployed for real, but via two one-off, hand-written
   workflow steps (PR #316 / #292) — adding a 4th pack today means writing a
   5th near-duplicate step.
2. **No coverage of "direct-module" mappings** — Resource Types whose only
   implementation is an AVM/third-party module reference written straight into
   a pack file, with no corresponding `recipes/<platform>/` folder elsewhere in
   the repo. Today that's 9 Resource Types, all in the Azure pack (MySQL,
   PostgreSQL, SQL Server, Redis, MongoDB, Kafka, Object Storage, AI Models, AI
   Search) — but nothing in the repo *detects* this set generically. It's
   whatever happens not to have a `recipes/azure/` folder today. A wrong AVM
   parameter name, or a wrong conditional mapping (e.g. `tls` →
   `require_secure_transport`), ships green.

**User requirement:** build this as a general framework that works for every
pack we have today (Kubernetes, Azure AKS, Azure ACI) and keeps working when
packs are added later, in both the per-PR and nightly test paths — not three
separate hand-wired test paths.

## The Framework

One shared script, `.github/scripts/lib-recipe-packs.sh`, is the single source
of truth that every other piece (existing and new) reads from. It answers
three questions, and everything else is built on top of its answers:

| Function | Answers |
|---|---|
| `list_recipe_packs` | "What packs exist?" — scans `recipe-packs/*/*.bicep` |
| `pack_platform_group <pack>` | "What platform does this pack target?" — small lookup table (`kubernetes` → `kubernetes`, `azure-aks`/`azure-aci` → `azure`); adding a *new platform* (e.g. a future AWS pack) means adding one line here, nothing else |
| `list_direct_module_types <pack>` | "Which Resource Types in this pack have no backing `recipes/<platform-group>/` folder in this repo?" — reads the pack's `recipes` map, and for each Resource Type key checks whether `<Category>/<type>/recipes/<platform-group>/` exists; if not (and the type has a `test/app.bicep`), it's a direct-module entry |

Because every pack and every direct-module gap is *discovered*, not
hand-listed, adding a 4th pack or a 10th direct-module entry needs **no new
test code** — only a config line if it's a genuinely new platform.

Three consumers read from this one library, one per testing layer:

- **Layer 1 — "does the committed pack still deploy?"**
  New `.github/scripts/deploy-all-checked-in-recipe-packs.sh <platform-group>
  <environment>` loops over `list_recipe_packs`, filters to the requested
  platform group, and deploys+associates each one (reusing the existing
  per-template parameter detection from `deploy-checked-in-azure-recipe-pack.sh`,
  generalized). This replaces the two hand-written Azure steps and adds the
  missing Kubernetes step, with one call per platform group:
  - `validate-resource-types.yaml` calls it with `kubernetes` (local k3d, free).
  - `validate-azure-recipes.yaml` calls it with `azure` (real Azure resources,
    already gated by the existing approval flow for forks).

- **Layer 2 — "are the direct-module mappings internally correct?"** (every PR,
  no cloud cost)
  New `.github/scripts/validate-direct-module-mappings.sh` loops over every
  pack, calls `list_direct_module_types`, and for each hit:
  1. Collects every `{{context.resource.properties.*}}` expression in that
     entry's `parameters`/`outputs`.
  2. Confirms each referenced property is actually declared in that Resource
     Type's YAML schema (catches typos/renames with zero deployment).
  3. For properties with a declared `enum` (e.g. `tls: [required, optional]`),
     evaluates the if/else expression inside `{{ ... }}` for every enum value with a
     tiny expression evaluator (`==`, `?:`, literals, property access — only
     the subset these packs actually use) and checks every value is handled
     and maps to an expected result (catches the `tls` →
     `require_secure_transport` class of bug from the issue).
  This runs once, against every pack, regardless of platform — today it will
  find 9 hits in `azure-aks` and 0 in the others, but that's a result of the
  scan, not something hardcoded.

- **Layer 3 — "does the direct-module mapping actually work against real
  infrastructure?"** (nightly, real cloud cost)
  New workflow, matrixed over platform groups returned by the same library.
  For each platform group: bring up its environment, run Layer 1's deploy
  script, then call `list_direct_module_types` again and, for each hit, run a
  new `.github/scripts/test-direct-module-recipe.sh <resource-type-path>
  <platform-group> <environment>` that deploys that type's `test/app.bicep` for
  real and asserts success (reusing shared deploy/assert logic refactored out
  of `test-recipe.sh` into a sourced library, so it works without needing a
  `recipes/<platform>/` folder to anchor on). Today this only does real work
  for the `azure` group (9 types); the `kubernetes` group's matrix leg deploys
  the pack and exits cleanly, and will start testing real resources
  automatically the day a direct-module Kubernetes entry is added — no new
  code required.

## Rollout

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
5. Build the nightly workflow (Layer 3), matrixed over platform groups, reusing
   steps 2 and 4.
6. Update docs: `recipe-packs/README.md` (how to add a pack / how coverage
   works) and `docs/contributing/testing-resource-types-recipes.md`.
7. Add script-level tests for every new script under `.github/scripts/tests/`,
   matching existing conventions (e.g. `test-validate-recipe-packs.sh`).

## What's Out of Scope

- Testing every possible value of a property, not just its declared `enum`
  values.
- Any new cloud platform support — the framework only covers platform groups
  that already have a CI job (`kubernetes`, `azure`) to plug into.

## Open Questions / Risks

- The exact grammar Radius uses for `{{...}}` recipe-context expressions isn't
  formally documented here; the Layer 2 evaluator is scoped to what's actually
  used in `recipe-packs/**` today and may need small extensions as new
  expression shapes are added.
- Nightly workflow needs the same `AZURE_*` secrets as
  `validate-azure-recipes.yaml` — confirm they're available to
  schedule/dispatch-triggered runs (expected yes, since it's not a fork PR).
