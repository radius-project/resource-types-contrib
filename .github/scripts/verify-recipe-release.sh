#!/bin/bash
# shellcheck disable=SC2016 # GraphQL and jq variables are not shell expansions.

# Read-only. Emit the frozen source and its attested subjects for a planned
# stable release. An unplanned, version-only dispatch uses the legacy builder.
set -euo pipefail

fail() { echo "Error: $*" >&2; exit 1; }
legacy_build() {
    [[ -z "$identifier$source" ]] || fail "No frozen recipe source in the committed Radius plan."
    echo 'source=checkout'
    exit 0
}
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

commit="$(gh api graphql -f tag="$tag" -f query='query($tag: String!) {
    repository(owner: "radius-project", name: "radius") {
      release(tagName: $tag) { tagName isDraft isPrerelease publishedAt tagCommit { oid } }
    }}' | jq -ser --arg tag "$tag" '.[0].data.repository.release |
        select(.tagName == $tag and .isDraft == false and .isPrerelease == ($tag | contains("-")) and .publishedAt)
        | .tagCommit.oid | strings | select(test("^[0-9a-f]{40}\\z"))')" ||
    fail "Expected a matching published Radius release for $tag."
[[ "$version" != *-* ]] || legacy_build # Manual prerelease: immutable tags only.
[[ -z "$identifier" || "$identifier" == "$tag-$commit" ]] ||
    fail "The Radius tag does not match the release identifier."

# A missing blob at a known commit is evidence of a historical release. An
# unknown commit, failed lookup, or unreadable blob must not select a rebuild.
blob="$(gh api graphql -f oid="$commit" -f path="$commit:.github/release-plans/$tag.yaml" -f query='
    query($oid: GitObjectID!, $path: String!) { repository(owner: "radius-project", name: "radius") {
      commit: object(oid: $oid) { oid }
      plan: object(expression: $path) { ... on Blob { isTruncated text } }
    }}' | jq -scer --arg commit "$commit" '.[0].data.repository |
        select(.commit.oid == $commit and has("plan")) | {plan}')" ||
    fail "Could not verify the Radius commit and its plan."
[[ "$blob" != '{"plan":null}' ]] || legacy_build

# Reject duplicate top-level keys or multiple documents rather than letting
# YAML-to-JSON conversion silently select one pin.
pinned="$(jq -er '.plan | select(.isTruncated == false) | .text | strings' <<<"$blob" |
    yq -o=json -I=0 'to_entries' |
    jq -esr --arg tag "$tag" 'if length == 1 and (.[0] | type == "array" and length > 0 and
        all(.[]; .key | type == "string") and length == (unique_by(.key) | length))
        then .[0] | from_entries else error("Invalid release plan mapping") end |
        select(.version == $tag and (.releaseType == "final" or .releaseType == "patch")) |
        if has("recipeSourceCommit") then .recipeSourceCommit | strings | select(test("^[0-9a-f]{40}\\z"))
        else "checkout" end')" ||
    fail "Invalid frozen recipe source in the stable release plan."
[[ "$pinned" != checkout ]] || legacy_build
[[ -z "$source" || "$source" == "$pinned" ]] || fail "recipeSourceCommit does not match the supplied source."
gh api "repos/$contrib/compare/$pinned...main?per_page=1" |
    jq -se --arg pin "$pinned" '.[0] | .merge_base_commit.sha == $pin' >/dev/null ||
    fail "The frozen recipe commit must be reachable on contrib main."

locator="$(mktemp)"
trap 'rm -f "$locator"' EXIT
printf '%s\n' "$pinned" >"$locator"
checksum="$(sha256sum <"$locator")"
# One verified statement covers the locator and the build's entire recipe set.
subjects="$(gh attestation verify "$locator" --repo "$contrib" \
    --signer-workflow "$contrib/.github/workflows/publish-bicep-recipes.yaml" \
    --source-ref refs/heads/main --source-digest "$pinned" --signer-digest "$pinned" \
    --deny-self-hosted-runners --format json | jq -er --arg checksum "${checksum%% *}" '
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
')" || fail "Could not verify the signed recipe inventory for $pinned. Check the original main publication."
[[ -n "$subjects" ]] || fail "The verified inventory contains no recipes."
printf 'source=%s\nsubjects<<EOF\n%s\nEOF\n' "$pinned" "$subjects"
