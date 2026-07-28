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
BUNDLE_SCRIPT="${REPO_ROOT}/.github/scripts/release/build-recipe-pack-bundle.sh"
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

create_repo() {
    local repo="$1" category="$2"
    git init -q "$repo"
    git -C "$repo" config user.name "Release Test"
    git -C "$repo" config user.email "release-test@example.com"
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
    git init -q "$repo"
    git -C "$repo" config user.name "Release Test"
    git -C "$repo" config user.email "release-test@example.com"
    mkdir -p "$repo/recipepack/$pack"
    cat >"$repo/recipepack/$pack/default-recipepack.bicep" <<'EOF'
extension radius
EOF
    echo "# ${pack} recipe pack" >"$repo/recipepack/$pack/README.md"
    git -C "$repo" add .
    git -C "$repo" commit -q -m "add ${pack} recipe pack"
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
    tar -tzf "$asset" | grep -q 'recipepack/kubernetes/default-recipepack.bicep' ||
        fail "recipe pack bundle is missing the pack template"
    tar -tzf "$asset" | grep -q 'recipepack/kubernetes/README.md' ||
        fail "recipe pack bundle is missing the pack README"
}

test_recipe_pack_release_is_not_synced() {
    local repo="$TEST_ROOT/recipe-pack-sync" output="$TEST_ROOT/recipe-pack-sync.out"
    create_repo "$repo" "Data"

    REPO_ROOT="$repo" EVENT_NAME=release RELEASE_TAG="recipe-pack/kubernetes/v0.1.0" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "0" "$(output_value "$output" namespace_count)" "recipe pack release namespace count"
    assert_eq "non-namespace-scope" "$(output_value "$output" reason)" "recipe pack release skip reason"
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
test_deleted_namespace
test_renamed_namespace
test_prerelease_labels
test_recipe_pack_versioning
test_recipe_pack_bundle
test_recipe_pack_release_is_not_synced
echo "Release automation tests passed"
