# Test Design: CI Coverage for Recipe Packs

Issue: #312

## Background

A **Recipe Pack** is a file that tells Radius how to create cloud resources
(databases, caches, storage, etc.) when a user asks for them. We keep three of
these files in this repo today — one for Kubernetes, two for Azure — and users
install them as-is.

Today, CI doesn't reliably test the real files we ship, and the little bit of
testing we do have was built by hand, one pack at a time. That doesn't scale:
every new pack we add means writing new CI steps from scratch.

## The Goal

Build one shared, reusable framework that:

- Automatically finds every pack in the repo (so a new pack is tested the
  moment it's added — no new CI code).
- Automatically finds every "gap" — a resource type a pack sets up using an
  outside module (like an Azure building block) with no matching test
  anywhere else in the repo.
- Tests every pack and every gap the same way, whether it's for Kubernetes,
  Azure, or whatever platform we add next.

## How a Pack Is Checked Today (the gap)

A pack lists, for each resource type, where its setup instructions come from.
Most entries point to recipes we already wrote and test elsewhere in this
repo. Some entries point straight to an outside building block instead (for
example, an official Azure "AVM" module) — these are the untested ones, 9 of
them today, all in the Azure pack (MySQL, PostgreSQL, SQL Server, Redis,
MongoDB, Kafka, Object Storage, AI Models, AI Search).

## The Shared Piece Everything Else Builds On

One small library figures out, for any pack:

1. **What packs exist** — just by scanning the `recipe-packs/` folder.
2. **What platform each pack targets** — Kubernetes or Azure today, using one
   tiny lookup table. Adding a new platform later (say, AWS) means adding one
   line here.
3. **Which resource types in a pack are "gaps"** — the ones backed only by an
   outside module, with no matching recipe folder elsewhere in the repo.

Everything below reads from this one library, so there is exactly one place
that knows "what packs and gaps exist," and three different tests reuse it.

## The Three Tests

### Test 1: Does every committed pack still deploy? (every PR, free)

Deploys the actual pack file, not a generated copy, for every pack found by
the library. Runs on a free local test cluster for the Kubernetes pack, and on
Azure for the Azure packs (reusing the Azure testing that already exists
today). Catches: the file being broken (bad syntax, missing pieces) before it
ever reaches a user.

### Test 2: Are the gap mappings set up correctly? (every PR, free)

For every "gap" resource type found by the library, checks that:

- every setting it reads (for example "the `tls` setting") is a real setting
  that's actually allowed on that resource.
- for settings with a fixed list of allowed values (`tls` is either `required`
  or `optional`), every allowed value is handled and produces the expected
  result.

No cloud resources are created — this is a fast, local check. This is how we
catch the exact kind of bug the issue calls out: a setting like `tls:
optional` silently mapping to the wrong underlying setting.

This test does **not** prove the resource actually deploys successfully. It
only proves the mapping logic is consistent and typo-free.

### Test 3: Does it actually work for real? (nightly, real cost)

Once a day, for every "gap" resource type the library finds (today, 9 — all
Azure; 0 for Kubernetes, since Kubernetes has no gaps right now), actually
deploy a small test app using it against real cloud resources, and check it
works. This is the only place we spend real Azure money/time, so it runs
nightly instead of on every PR.

Because this test also reads from the shared library instead of a hand-typed
list, the moment someone adds a new gap — to any pack, on any platform — this
test starts covering it automatically, with no new code.

## Why Split It This Way

| | Runs on | Cost | Catches |
|---|---|---|---|
| Test 1 | Every PR | Free | A pack file is broken |
| Test 2 | Every PR | Free | Typos and wrong-value mappings in any pack's gaps |
| Test 3 | Nightly | Real cloud cost | Actual deployment failures for gap resource types |

Putting Test 3 on every PR would mean ~9 new real cloud resources created and
torn down on every single pull request, which is slow and costly for
something most PRs don't even touch. This split keeps every-PR checks fast
and free while still getting daily, real-world confidence.

## What's Out of Scope

- Testing every possible value of a setting — only the values a resource
  type's definition says are actually allowed.
- Support for cloud platforms that don't already have a CI pipeline here.

## Rollout Order

1. Build the shared library (pack discovery + gap detection).
2. Make Test 1 use it for all packs, including the Kubernetes one that's
   currently untested.
3. Build Test 2 (the free, every-PR mapping check).
4. Build Test 3 (the nightly real-deployment check), reusing Test 1 and the
   shared library.
5. Update contributor docs so this is how future packs and gaps get covered,
   automatically.
