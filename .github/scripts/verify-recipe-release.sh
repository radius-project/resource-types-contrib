#!/bin/bash

# Read-only. Emit the frozen source and its attested subjects for a planned
# stable release. An unplanned, version-only dispatch uses the legacy builder.
set -euo pipefail

fail() { echo "Error: $*" >&2; exit 1; }
legacy_build() { echo 'mode=build'; exit 0; }
radius='radius-project/radius'
contrib='radius-project/resource-types-contrib'
version="${RELEASE_VERSION:?A release version is required.}"
tag="v$version"
identifier="${RELEASE_IDENTIFIER:-}"
source="${RECIPE_SOURCE_COMMIT:-}"
sha='^[0-9a-f]{40}$'

GITHUB_OUTPUT='' COMMIT_SHA="${GITHUB_SHA:?}" bash "$(dirname "$0")/resolve-recipe-tags.sh" >/dev/null
if [[ -n "$identifier$source" ]]; then
    [[ "$version" != *-* && "$source" =~ $sha && -n "$identifier" ]] ||
        fail "The final handoff requires a stable version, its vX.Y.Z-<Radius SHA> identifier and a full recipe source SHA."
fi

gh api "repos/$radius/releases/tags/$tag" |
    jq -e --arg tag "$tag" '.tag_name == $tag and .draft == false and
        .prerelease == ($tag | contains("-")) and (.published_at | type == "string" and length > 0)' >/dev/null ||
    fail "Expected a matching published Radius release for $tag."
[[ "$version" != *-* ]] || legacy_build # Manual prerelease: immutable tags only.

# Use a fully qualified tag (also peels annotated tags), never target_commitish
# or a branch. Read the plan at that exact commit, not at a moving ref.
commit="$(gh api "repos/$radius/commits/refs/tags/$tag" --jq .sha)"
[[ "$commit" =~ $sha && ( -z "$identifier" || "$identifier" == "$tag-$commit" ) ]] ||
    fail "The Radius tag does not match the release identifier."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
status="$(curl --silent --show-error --location --output "$work/plan.yaml" --write-out '%{http_code}' \
    "https://raw.githubusercontent.com/$radius/$commit/.github/release-plans/$tag.yaml")"
[[ "$status" != 404 || -n "$identifier" ]] || legacy_build # Historical release without a plan.
[[ "$status" == 200 ]] || fail "Could not read the committed Radius release plan (HTTP $status)."

# Reject duplicate top-level keys or multiple documents rather than letting
# YAML-to-JSON conversion silently select one pin.
yq -o=json -I=0 'to_entries' "$work/plan.yaml" |
    jq -esc 'if length == 1 and (.[0] | type == "array" and length > 0 and
        all(.[]; .key | type == "string") and length == (unique_by(.key) | length))
        then .[0] | from_entries else error("Invalid release plan mapping") end' >"$work/plan.json"
has_pin="$(jq -r 'has("recipeSourceCommit")' "$work/plan.json")"
if [[ "$has_pin" == false ]]; then
    [[ -z "$identifier" ]] || fail "No top-level recipeSourceCommit in the release plan."
    legacy_build # Never take this path with handoff inputs.
fi
pinned="$(jq -er --arg tag "$tag" 'select(.version == $tag and (.releaseType == "final" or .releaseType == "patch"))
    | .recipeSourceCommit | strings | select(test("^[0-9a-f]{40}\\z"))' "$work/plan.json")" ||
    fail "Invalid frozen recipe source in the stable release plan."
[[ -z "$source" || "$source" == "$pinned" ]] || fail "recipeSourceCommit does not match the supplied source."
gh api "repos/$contrib/compare/$pinned...main?per_page=1" |
    jq -e --arg pin "$pinned" '.merge_base_commit.sha == $pin and (.status == "ahead" or .status == "identical")' >/dev/null ||
    fail "The frozen recipe commit must be reachable on contrib main."

printf '%s\n' "$pinned" >"$work/recipe-source.txt"
checksum="$(sha256sum <"$work/recipe-source.txt")"
gh attestation verify "$work/recipe-source.txt" --repo "$contrib" \
    --signer-workflow "$contrib/.github/workflows/publish-bicep-recipes.yaml" \
    --source-ref refs/heads/main --source-digest "$pinned" --signer-digest "$pinned" \
    --deny-self-hosted-runners --format json >"$work/verified.json" ||
    fail "No matching signed recipe build inventory for $pinned. Check the original main publication."

# One statement signs both the locator and every recipe built at this commit.
# Retries may sign the same inventory again, but must never disagree.
jq -er --arg checksum "${checksum%% *}" '
    [.[].verificationResult.statement.subject |
        if [.[] | select(.name == "recipe-source.txt")] != [{name: "recipe-source.txt", digest: {sha256: $checksum}}]
        then error("Invalid recipe source locator") end |
        map(select(.name != "recipe-source.txt")) | sort_by(.name) |
        if length == 0 or length != (unique_by(.name) | length) or
            (all(.[]; (.name | test("^ghcr\\.io/radius-project/[a-z0-9-]+-recipes/[a-z0-9]+(-[a-z0-9]+)*\\z")) and
                (.digest.sha256 | test("^[0-9a-f]{64}\\z"))) | not)
        then error("Invalid signed recipe inventory") end |
        map("\(.digest.sha256)  \(.name)")
    ] | unique | if length == 1 then .[0][] else error("Missing or conflicting signed recipe inventories") end
' "$work/verified.json" >"$work/subjects"

printf 'mode=promote\nsource=%s\nsubjects<<EOF\n' "$pinned"
cat "$work/subjects"
echo EOF
