#!/bin/bash

# ------------------------------------------------------------
# Copyright 2025 The Radius Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SYNC_SCRIPT="${REPO_ROOT}/.github/scripts/compute-radius-sync-payload.sh"
VERSION_SCRIPT="${REPO_ROOT}/.github/scripts/release/next-version.sh"
CHANGES_SCRIPT="${REPO_ROOT}/.github/scripts/release/detect-changes.sh"
BUNDLE_SCRIPT="${REPO_ROOT}/.github/scripts/release/build-recipe-pack-bundle.sh"
TAGS_SCRIPT="${REPO_ROOT}/.github/scripts/resolve-recipe-tags.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-release-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local want="$1" got="$2" message="$3"
    [[ "$got" == "$want" ]] || fail "$message: got '$got', want '$want'"
}

output_value() {
    local file="$1" key="$2"
    sed -n "s/^${key}=//p" "$file" | tail -n1
}

# Local repo config beats the developer's global config, so fixtures still
# commit and tag on machines that enforce signing.
init_repo() {
    local repo="$1"
    git init -q "$repo"
    git -C "$repo" config user.name "Release Test"
    git -C "$repo" config user.email "release-test@example.com"
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" config tag.gpgSign false
}

create_repo() {
    local repo="$1" category="$2"
    init_repo "$repo"
    mkdir -p "$repo/$category/widgets"
    cat >"$repo/$category/widgets/widget.yaml" <<EOF
namespace: Radius.${category}
types:
  widgets:
    apiVersions:
      '2025-01-01-preview':
        schema: {}
EOF
    git -C "$repo" add .
    git -C "$repo" commit -q -m "add ${category} manifest"
}

create_recipe_pack_repo() {
    local repo="$1" pack="$2"
    init_repo "$repo"
    mkdir -p "$repo/recipe-packs/$pack"
    cat >"$repo/recipe-packs/$pack/default-recipepack.bicep" <<'EOF'
extension radius
EOF
    echo "# ${pack} recipe pack" >"$repo/recipe-packs/$pack/README.md"
    git -C "$repo" add .
    git -C "$repo" commit -q -m "add ${pack} recipe pack"
}

commit_file() {
    local repo="$1" path="$2" content="$3" message="$4"
    mkdir -p "$repo/$(dirname "$path")"
    printf '%s\n' "$content" >"$repo/$path"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "$message"
}

# Run detect-changes.sh for one released unit, writing its outputs to $output.
detect_changes() {
    local repo="$1" output="$2" unit_var="$3" unit="$4"
    : >"$output"
    env REPO_ROOT="$repo" GITHUB_OUTPUT="$output" "${unit_var}=${unit}" \
        bash "$CHANGES_SCRIPT" >/dev/null 2>&1 ||
        fail "change detection failed for ${unit}"
}

test_deleted_namespace() {
    local repo="$TEST_ROOT/deleted" output="$TEST_ROOT/deleted.out" before after
    create_repo "$repo" "Security"
    before="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" rm -q Security/widgets/widget.yaml
    git -C "$repo" commit -q -m "delete Security manifest"
    after="$(git -C "$repo" rev-parse HEAD)"

    REPO_ROOT="$repo" EVENT_NAME=push BEFORE_SHA="$before" AFTER_SHA="$after" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "1" "$(output_value "$output" namespace_count)" "deleted namespace count"
    assert_eq "Radius.Security" "$(output_value "$output" affected)" "deleted namespace"
}

test_renamed_namespace() {
    local repo="$TEST_ROOT/renamed" output="$TEST_ROOT/renamed.out" before after
    create_repo "$repo" "Data"
    before="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" mv Data Compute
    sed -i 's/Radius\.Data/Radius.Compute/' "$repo/Compute/widgets/widget.yaml"
    git -C "$repo" add .
    git -C "$repo" commit -q -m "rename Data namespace to Compute"
    after="$(git -C "$repo" rev-parse HEAD)"

    REPO_ROOT="$repo" EVENT_NAME=push BEFORE_SHA="$before" AFTER_SHA="$after" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "2" "$(output_value "$output" namespace_count)" "renamed namespace count"
    assert_eq "Radius.Data,Radius.Compute" "$(output_value "$output" affected)" "renamed namespaces"
}

test_prerelease_labels() {
    local repo="$TEST_ROOT/prerelease" label
    create_repo "$repo" "Data"

    REPO_ROOT="$repo" NAMESPACE=Radius.Data BUMP=minor PRERELEASE_LABEL=rc.1 \
        bash "$VERSION_SCRIPT" >/dev/null 2>&1 || fail "valid prerelease label rc.1 was rejected"

    for label in rc..1 rc.01 01 .rc rc.; do
        if REPO_ROOT="$repo" NAMESPACE=Radius.Data BUMP=minor PRERELEASE_LABEL="$label" \
            bash "$VERSION_SCRIPT" >/dev/null 2>&1; then
            fail "invalid prerelease label '$label' was accepted"
        fi
    done
}

test_recipe_pack_versioning() {
    local repo="$TEST_ROOT/recipe-pack" output="$TEST_ROOT/recipe-pack.out"
    create_recipe_pack_repo "$repo" "kubernetes"

    REPO_ROOT="$repo" RECIPE_PACK=kubernetes BUMP=minor GITHUB_OUTPUT="$output" \
        bash "$VERSION_SCRIPT" >/dev/null 2>&1 || fail "initial recipe pack version was rejected"
    assert_eq "none" "$(output_value "$output" current)" "initial recipe pack current version"
    assert_eq "recipe-pack/kubernetes/v0.1.0" "$(output_value "$output" tag)" "initial recipe pack tag"

    git -C "$repo" tag "recipe-pack/kubernetes/v0.1.0"
    : >"$output"
    REPO_ROOT="$repo" RECIPE_PACK=kubernetes BUMP=patch PRERELEASE_LABEL=rc.1 \
        GITHUB_OUTPUT="$output" bash "$VERSION_SCRIPT" >/dev/null 2>&1 ||
        fail "recipe pack patch bump was rejected"
    assert_eq "0.1.0" "$(output_value "$output" current)" "recipe pack current version"
    assert_eq "recipe-pack/kubernetes/v0.1.1-rc.1" "$(output_value "$output" tag)" "recipe pack prerelease tag"
    assert_eq "true" "$(output_value "$output" is_prerelease)" "recipe pack prerelease flag"

    if REPO_ROOT="$repo" RECIPE_PACK=does-not-exist bash "$VERSION_SCRIPT" >/dev/null 2>&1; then
        fail "unknown recipe pack was accepted"
    fi

    if REPO_ROOT="$repo" NAMESPACE=Radius.Data RECIPE_PACK=kubernetes \
        bash "$VERSION_SCRIPT" >/dev/null 2>&1; then
        fail "NAMESPACE and RECIPE_PACK together were accepted"
    fi
}

test_recipe_pack_bundle() {
    local repo="$TEST_ROOT/recipe-pack-bundle" output="$TEST_ROOT/recipe-pack-bundle.out" asset
    create_recipe_pack_repo "$repo" "kubernetes"

    (cd "$repo" && REPO_ROOT="$repo" RECIPE_PACK=kubernetes VERSION=0.1.0 \
        GITHUB_OUTPUT="$output" bash "$BUNDLE_SCRIPT" >/dev/null 2>&1) ||
        fail "recipe pack bundle build failed"

    asset="$(output_value "$output" asset)"
    assert_eq "recipe-pack-kubernetes-v0.1.0.tar.gz" "$(basename "$asset")" "recipe pack asset name"
    assert_eq "1" "$(output_value "$output" count)" "recipe pack template count"
    [[ -f "$asset" ]] || fail "recipe pack asset was not created"
    tar -tzf "$asset" | grep -q 'recipe-packs/kubernetes/default-recipepack.bicep' ||
        fail "recipe pack bundle is missing the pack template"
    tar -tzf "$asset" | grep -q 'recipe-packs/kubernetes/README.md' ||
        fail "recipe pack bundle is missing the pack README"
}

test_recipe_pack_release_is_synced() {
    local repo="$TEST_ROOT/recipe-pack-sync" output="$TEST_ROOT/recipe-pack-sync.out" payload
    create_recipe_pack_repo "$repo" "kubernetes"

    REPO_ROOT="$repo" EVENT_NAME=release RELEASE_TAG="recipe-pack/kubernetes/v0.1.0" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "0" "$(output_value "$output" namespace_count)" "recipe pack release namespace count"
    assert_eq "1" "$(output_value "$output" recipe_pack_count)" "recipe pack release pack count"
    assert_eq "kubernetes" "$(output_value "$output" affected_recipe_packs)" "recipe pack release affected pack"

    payload="$(output_value "$output" payload)"
    assert_eq '[{"name":"kubernetes","ref":"recipe-pack/kubernetes/v0.1.0"}]' \
        "$(jq -c '.recipe_packs' <<<"$payload")" "recipe pack release payload pins"
    assert_eq "[]" "$(jq -c '.namespaces' <<<"$payload")" "recipe pack release payload namespaces"

    : >"$output"
    REPO_ROOT="$repo" EVENT_NAME=release RELEASE_TAG="recipe-pack/does-not-exist/v0.1.0" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "0" "$(output_value "$output" unit_count)" "unknown recipe pack unit count"
    assert_eq "unknown-recipe-pack" "$(output_value "$output" reason)" "unknown recipe pack skip reason"
}

test_recipe_pack_push_is_synced() {
    local repo="$TEST_ROOT/recipe-pack-push" output="$TEST_ROOT/recipe-pack-push.out" before after payload
    create_recipe_pack_repo "$repo" "azure"
    before="$(git -C "$repo" rev-parse HEAD)"
    echo "// updated" >>"$repo/recipe-packs/azure/default-recipepack.bicep"
    git -C "$repo" commit -q -am "update azure recipe pack"
    after="$(git -C "$repo" rev-parse HEAD)"

    REPO_ROOT="$repo" EVENT_NAME=push BEFORE_SHA="$before" AFTER_SHA="$after" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "0" "$(output_value "$output" namespace_count)" "recipe pack push namespace count"
    assert_eq "azure" "$(output_value "$output" affected_recipe_packs)" "recipe pack push affected pack"

    payload="$(output_value "$output" payload)"
    assert_eq "$after" "$(jq -r '.recipe_packs[0].ref' <<<"$payload")" "recipe pack push pin ref"
}

test_repo_wide_release_covers_all_units() {
    local repo="$TEST_ROOT/repo-wide" output="$TEST_ROOT/repo-wide.out" payload
    create_repo "$repo" "Data"
    mkdir -p "$repo/recipe-packs/kubernetes"
    echo "extension radius" >"$repo/recipe-packs/kubernetes/default-recipepack.bicep"
    git -C "$repo" add .
    git -C "$repo" commit -q -m "add kubernetes recipe pack"

    REPO_ROOT="$repo" EVENT_NAME=release RELEASE_TAG="v0.1.0" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "2" "$(output_value "$output" unit_count)" "repo-wide release unit count"
    assert_eq "Radius.Data" "$(output_value "$output" affected)" "repo-wide release namespaces"
    assert_eq "kubernetes" "$(output_value "$output" affected_recipe_packs)" "repo-wide release recipe packs"

    # Radius reads `name` and accepts `namespace` as a legacy alias; both must
    # be present so one payload works with either consumer version.
    payload="$(output_value "$output" payload)"
    assert_eq "Radius.Data" "$(jq -r '.namespaces[0].name' <<<"$payload")" "repo-wide namespace name"
    assert_eq "Radius.Data" "$(jq -r '.namespaces[0].namespace' <<<"$payload")" "repo-wide namespace alias"
}

test_release_change_detection() {
    local repo="$TEST_ROOT/changes" output="$TEST_ROOT/changes.out"
    create_repo "$repo" "Data"
    commit_file "$repo" "recipe-packs/kubernetes/default-recipepack.bicep" \
        "extension radius" "add kubernetes recipe pack"

    # Never released: there is always something to publish.
    detect_changes "$repo" "$output" NAMESPACE Radius.Data
    assert_eq "true" "$(output_value "$output" changed)" "unreleased namespace changed"
    assert_eq "no-previous-release" "$(output_value "$output" reason)" "unreleased namespace reason"
    assert_eq "none" "$(output_value "$output" previous_tag)" "unreleased namespace baseline"

    git -C "$repo" tag "Radius.Data/v0.1.0"
    git -C "$repo" tag "recipe-pack/kubernetes/v0.1.0"

    # Released at this very commit: nothing new to publish.
    detect_changes "$repo" "$output" NAMESPACE Radius.Data
    assert_eq "false" "$(output_value "$output" changed)" "released namespace changed"
    assert_eq "no-changes" "$(output_value "$output" reason)" "released namespace reason"
    assert_eq "Radius.Data/v0.1.0" "$(output_value "$output" previous_tag)" "released namespace baseline"

    # Test applications never ship, so they are not a reason to release.
    commit_file "$repo" "Data/widgets/test/app.bicep" "extension radius" "add widget test app"
    detect_changes "$repo" "$output" NAMESPACE Radius.Data
    assert_eq "false" "$(output_value "$output" changed)" "test-only change changed"

    # A recipe does ship: it is published under the release commit's SHA.
    commit_file "$repo" "Data/widgets/recipes/kubernetes/bicep/widget.bicep" \
        "param context object" "add widget recipe"
    detect_changes "$repo" "$output" NAMESPACE Radius.Data
    assert_eq "true" "$(output_value "$output" changed)" "recipe change changed"
    assert_eq "1" "$(output_value "$output" count)" "recipe change file count"

    # Independent lifecycles: namespace churn must not release the recipe pack.
    detect_changes "$repo" "$output" RECIPE_PACK kubernetes
    assert_eq "false" "$(output_value "$output" changed)" "unrelated namespace change changed the pack"

    commit_file "$repo" "recipe-packs/kubernetes/default-recipepack.bicep" \
        "extension radius // updated" "update kubernetes recipe pack"
    detect_changes "$repo" "$output" RECIPE_PACK kubernetes
    assert_eq "true" "$(output_value "$output" changed)" "recipe pack change changed"

    # A reverted change leaves nothing to publish, even though commits exist.
    local pack_repo="$TEST_ROOT/changes-revert" pack_output="$TEST_ROOT/changes-revert.out"
    create_recipe_pack_repo "$pack_repo" "azure"
    git -C "$pack_repo" tag "recipe-pack/azure/v0.1.0"
    commit_file "$pack_repo" "recipe-packs/azure/default-recipepack.bicep" \
        "extension radius // temporary" "tweak azure recipe pack"
    commit_file "$pack_repo" "recipe-packs/azure/default-recipepack.bicep" \
        "extension radius" "revert azure recipe pack tweak"
    detect_changes "$pack_repo" "$pack_output" RECIPE_PACK azure
    assert_eq "false" "$(output_value "$pack_output" changed)" "reverted change changed"

    # Prereleases are staging artifacts, so they are never the baseline --
    # promoting one to a stable release must not be blocked.
    git -C "$repo" tag "Radius.Data/v0.2.0-rc.1"
    detect_changes "$repo" "$output" NAMESPACE Radius.Data
    assert_eq "Radius.Data/v0.1.0" "$(output_value "$output" previous_tag)" "prerelease used as baseline"
    assert_eq "true" "$(output_value "$output" changed)" "prerelease promotion changed"
}

test_recipe_tags() {
    local sha="0123456789abcdef0123456789abcdef01234567"

    # The commit SHA is unconditional: Radius pins a namespace to a SHA and
    # reuses it verbatim as the recipe's OCI tag, so every publish must produce
    # that tag no matter which channel triggered it.
    assert_eq "$sha edge" "$(COMMIT_SHA="$sha" bash "$TAGS_SCRIPT")" "edge tags"
    assert_eq "$sha 0.51.0 latest" \
        "$(COMMIT_SHA="$sha" RELEASE_VERSION=0.51.0 bash "$TAGS_SCRIPT")" "stable release tags"
    assert_eq "$sha 0.51.0-rc.1" \
        "$(COMMIT_SHA="$sha" RELEASE_VERSION=0.51.0-rc.1 bash "$TAGS_SCRIPT")" "prerelease tags"
    assert_eq "$sha" \
        "$(COMMIT_SHA="$sha" PIN_ONLY=true bash "$TAGS_SCRIPT")" "pin-only tags"

    # An abbreviated or uppercase SHA would never match the pin Radius records.
    for bad in "${sha:0:7}" "${sha^^}" "" "not-a-sha"; do
        if COMMIT_SHA="$bad" bash "$TAGS_SCRIPT" >/dev/null 2>&1; then
            fail "invalid commit SHA '$bad' was accepted"
        fi
    done
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
test_deleted_namespace
test_renamed_namespace
test_prerelease_labels
test_recipe_pack_versioning
test_recipe_pack_bundle
test_recipe_pack_release_is_synced
test_recipe_pack_push_is_synced
test_repo_wide_release_covers_all_units
test_release_change_detection
test_recipe_tags
echo "Release automation tests passed"
