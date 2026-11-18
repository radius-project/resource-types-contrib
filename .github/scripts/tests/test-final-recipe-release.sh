#!/bin/bash

# Offline fixtures for the cross-repo release and provenance verification.
set -euo pipefail
helper="$(cd "$(dirname "$0")/.." && pwd)/verify-recipe-release.sh"
FIXTURE="$(mktemp -d)"
export FIXTURE
trap 'rm -rf "$FIXTURE"' EXIT
export RADIUS_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export PIN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export GITHUB_SHA=cccccccccccccccccccccccccccccccccccccccc
export RELEASE_VERSION=0.63.1 RELEASE_IDENTIFIER="v0.63.1-$RADIUS_SHA" RECIPE_SOURCE_COMMIT="$PIN"
mkdir "$FIXTURE/bin"
export PATH="$FIXTURE/bin:$PATH"
cat >"$FIXTURE/bin/gh" <<'EOF'
#!/bin/bash
set -eu
case "$1 $2" in
"api repos/radius-project/radius/releases/tags/v$RELEASE_VERSION") cat "$FIXTURE/release" ;;
"api repos/radius-project/radius/commits/refs/tags/v$RELEASE_VERSION") echo "$RADIUS_SHA" ;;
"api repos/radius-project/resource-types-contrib/compare/$PIN...main?per_page=1") cat "$FIXTURE/comparison" ;;
"attestation verify")
    [[ "$(cat "$3")" == "$PIN" ]] || exit 1
    shift 3
    repo='radius-project/resource-types-contrib'
    [[ "$*" == "--repo $repo --signer-workflow $repo/.github/workflows/publish-bicep-recipes.yaml --source-ref refs/heads/main --source-digest $PIN --signer-digest $PIN --deny-self-hosted-runners --format json" ]] || exit 1
    cat "$FIXTURE/verified"
    ;;
*) echo "Unexpected gh request: $*" >&2; exit 1 ;;
esac
EOF
cat >"$FIXTURE/bin/curl" <<'EOF'
#!/bin/bash
set -eu
[[ "${!#}" == "https://raw.githubusercontent.com/radius-project/radius/$RADIUS_SHA/.github/release-plans/v$RELEASE_VERSION.yaml" ]]
while [[ "$1" != --output ]]; do shift; done
cp "$FIXTURE/plan" "$2"
echo "${HTTP_STATUS:-200}"
EOF
chmod +x "$FIXTURE/bin/"*
echo '{"tag_name":"v0.63.1","prerelease":false,"draft":false,"published_at":"2026-11-01"}' >"$FIXTURE/release"
printf '{"merge_base_commit":{"sha":"%s"},"status":"ahead"}\n' "$PIN" >"$FIXTURE/comparison"
plan() { printf 'version: v0.63.1\nreleaseType: %s\nrecipeSourceCommit: %s\n' "$1" "$2" >"$FIXTURE/plan"; }
locator="$(printf '%s\n' "$PIN" | sha256sum)"
digest="$(printf '1%.0s' {1..64})"
image='ghcr.io/radius-project/kube-recipes/containers'
jq -n --arg loc "${locator%% *}" --arg checksum "$digest" --arg image "$image" \
    '[{verificationResult:{statement:{subject:[{name:"recipe-source.txt",digest:{sha256:$loc}},
        {name:$image,digest:{sha256:$checksum}}]}}}]' >"$FIXTURE/good"
cp "$FIXTURE/good" "$FIXTURE/verified"

reject() {
    if "$@" >"$FIXTURE/output" 2>"$FIXTURE/error"; then echo "Expected rejection: $*" >&2; exit 1; fi
    [[ ! -s "$FIXTURE/output" ]] || { echo "Failed verifier returned promotion subjects." >&2; exit 1; }
}
expected="$(printf 'mode=promote\nsource=%s\nsubjects<<EOF\n%s  %s\nEOF' "$PIN" "$digest" "$image")"
plan final "$PIN"
[[ "$(bash "$helper")" == "$expected" ]]
plan patch "$PIN"
[[ "$(RELEASE_IDENTIFIER='' RECIPE_SOURCE_COMMIT='' bash "$helper")" == "$expected" ]]
reject env RELEASE_IDENTIFIER='' bash "$helper"
reject env RECIPE_SOURCE_COMMIT='' bash "$helper"
reject env RELEASE_VERSION=0.63.1-rc.1 RELEASE_IDENTIFIER="v0.63.1-rc.1-$RADIUS_SHA" bash "$helper"
reject env RELEASE_IDENTIFIER="v0.63.1-$GITHUB_SHA" bash "$helper"
reject env RECIPE_SOURCE_COMMIT="$GITHUB_SHA" bash "$helper"
reject env HTTP_STATUS=404 bash "$helper"
reject env RELEASE_IDENTIFIER='' RECIPE_SOURCE_COMMIT='' HTTP_STATUS=503 bash "$helper"
[[ "$(RELEASE_IDENTIFIER='' RECIPE_SOURCE_COMMIT='' HTTP_STATUS=404 bash "$helper")" == 'mode=build' ]]

echo "source: {recipeSourceCommit: $PIN}" >"$FIXTURE/plan"
reject bash "$helper"
[[ "$(RELEASE_IDENTIFIER='' RECIPE_SOURCE_COMMIT='' bash "$helper")" == 'mode=build' ]]
plan rc "$PIN"
reject bash "$helper"
plan final null
reject env RELEASE_IDENTIFIER='' RECIPE_SOURCE_COMMIT='' bash "$helper"
plan final "$GITHUB_SHA"
echo "recipeSourceCommit: $PIN" >>"$FIXTURE/plan"
reject bash "$helper"
plan final "$PIN"

# A rebuilt or differently named subject must not be substituted. A second,
# identical attestation is fine; two different inventories for one pin are not.
jq '. + .' "$FIXTURE/good" >"$FIXTURE/verified"
[[ "$(bash "$helper")" == "$expected" ]]
for filter in '[]' '.[0].verificationResult.statement.subject |= .[0:1]' \
    '.[0].verificationResult.statement.subject[0].digest.sha256 = "wrong"' \
    '.[0].verificationResult.statement.subject[1].name = "ghcr.io/other/kube-recipes/demo"' \
    '.[0].verificationResult.statement.subject[1].digest.sha256 = "short"' \
    '. + (.[0].verificationResult.statement.subject[1].name += "-other")'; do
    jq "$filter" "$FIXTURE/good" >"$FIXTURE/verified"
    reject bash "$helper"
done
cp "$FIXTURE/good" "$FIXTURE/verified"
echo '{"merge_base_commit":{"sha":"detached"},"status":"diverged"}' >"$FIXTURE/comparison"
reject bash "$helper"
printf '{"merge_base_commit":{"sha":"%s"},"status":"identical"}\n' "$PIN" >"$FIXTURE/comparison"
echo '{"tag_name":"v0.63.1","prerelease":false,"draft":true,"published_at":null}' >"$FIXTURE/release"
reject bash "$helper"
echo '{"tag_name":"v0.63.1-rc.1","prerelease":true,"draft":false,"published_at":"2026-11-01"}' >"$FIXTURE/release"
result="$(RELEASE_IDENTIFIER='' RECIPE_SOURCE_COMMIT='' RELEASE_VERSION=0.63.1-rc.1 bash "$helper")"
[[ "$result" == 'mode=build' ]]
echo "Final recipe release verification tests passed"
