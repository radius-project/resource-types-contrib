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
LIST_NAMESPACES_SCRIPT="${REPO_ROOT}/.github/scripts/release/list-namespaces.sh"
NOTIFY_WORKFLOW="${REPO_ROOT}/.github/workflows/notify-radius.yaml"
NAMESPACE_WORKFLOW="${REPO_ROOT}/.github/workflows/release-namespace.yaml"
PUBLISH_WORKFLOW="${REPO_ROOT}/.github/workflows/publish-bicep-recipes.yaml"
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

test_release_notification_guards() {
    local repo="$TEST_ROOT/stable-only" output="$TEST_ROOT/stable-only.out"
    create_repo "$repo" "Data"

    REPO_ROOT="$repo" EVENT_NAME=release RELEASE_TAG="Radius.Data/v1.0.0" \
        RELEASE_PRERELEASE=false GITHUB_OUTPUT="$output" \
        bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "release" "$(output_value "$output" channel)" "stable release channel"
    assert_eq "1" "$(output_value "$output" unit_count)" "stable release unit count"
    assert_eq "Radius.Data" "$(output_value "$output" affected)" "stable release namespace"

    : >"$output"
    REPO_ROOT="$repo" EVENT_NAME=release RELEASE_TAG="Radius.Data/v1.1.0-rc.1" \
        RELEASE_PRERELEASE=true GITHUB_OUTPUT="$output" \
        bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "0" "$(output_value "$output" unit_count)" "prerelease unit count"
    assert_eq "prerelease" "$(output_value "$output" reason)" "prerelease skip reason"

    for invalid_tag in \
        docs-2026 \
        Radius.Data/v1.1.0-rc.1 \
        Radius.Data/v01.1.0 \
        Radius.Data/extra/v1.1.0 \
        recipe-pack/kubernetes/extra/v1.1.0; do
        : >"$output"
        REPO_ROOT="$repo" EVENT_NAME=release RELEASE_TAG="$invalid_tag" \
            RELEASE_PRERELEASE=false GITHUB_OUTPUT="$output" \
            bash "$SYNC_SCRIPT" >/dev/null 2>&1
        assert_eq "0" "$(output_value "$output" unit_count)" \
            "invalid stable release tag unit count"
        assert_eq "invalid-release-tag" "$(output_value "$output" reason)" \
            "invalid stable release tag skip reason"
    done

    grep -qE '^[[:space:]]{6}- released$' "$NOTIFY_WORKFLOW" ||
        fail "notify workflow is not subscribed to stable release events"
    grep -qE '^[[:space:]]{2}push:' "$NOTIFY_WORKFLOW" ||
        fail "notify workflow has no edge fallback trigger"
    grep -qE '^[[:space:]]{2}queue:[[:space:]]+max$' "$NOTIFY_WORKFLOW" ||
        fail "notify workflow can discard pending edge fallback pushes"
    grep -qE '^[[:space:]]{2}group:[[:space:]]+notify-radius$' "$NOTIFY_WORKFLOW" ||
        fail "edge and release notifications can race in separate groups"
}

test_edge_fallback_until_stable_release() {
    local repo="$TEST_ROOT/edge-fallback" output="$TEST_ROOT/edge-fallback.out"
    local before after payload
    create_repo "$repo" "Data"
    mkdir -p "$repo/recipe-packs/kubernetes"
    echo "extension radius" >"$repo/recipe-packs/kubernetes/default-recipepack.bicep"
    git -C "$repo" add .
    git -C "$repo" commit -q -m "add kubernetes recipe pack"

    # Prereleases are not stable baselines, so both units still use edge.
    git -C "$repo" tag "Radius.Data/v0.1.0-rc.1"
    git -C "$repo" tag "recipe-pack/kubernetes/v0.1.0-rc.1"
    before="$(git -C "$repo" rev-parse HEAD)"
    echo "# updated" >>"$repo/Data/widgets/widget.yaml"
    echo "// updated" >>"$repo/recipe-packs/kubernetes/default-recipepack.bicep"
    git -C "$repo" commit -q -am "update unreleased units"
    after="$(git -C "$repo" rev-parse HEAD)"

    REPO_ROOT="$repo" EVENT_NAME=push BEFORE_SHA="$before" AFTER_SHA="$after" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "edge" "$(output_value "$output" channel)" "edge fallback channel"
    assert_eq "Radius.Data" "$(output_value "$output" affected)" "edge fallback namespace"
    assert_eq "kubernetes" "$(output_value "$output" affected_recipe_packs)" \
        "edge fallback recipe pack"
    payload="$(output_value "$output" payload)"
    assert_eq "$after" "$(jq -r '.namespaces[0].ref' <<<"$payload")" \
        "edge fallback namespace ref"
    assert_eq "$after" "$(jq -r '.recipe_packs[0].ref' <<<"$payload")" \
        "edge fallback recipe pack ref"

    # A recipe-only change still advances an unreleased namespace because
    # Radius resolves that namespace pin to the recipe's SHA-tagged OCI image.
    before="$after"
    mkdir -p "$repo/Data/widgets/recipes/kubernetes/bicep"
    echo "param context object" >"$repo/Data/widgets/recipes/kubernetes/bicep/widget.bicep"
    git -C "$repo" add .
    git -C "$repo" commit -q -m "update unreleased namespace recipe"
    after="$(git -C "$repo" rev-parse HEAD)"
    : >"$output"

    REPO_ROOT="$repo" EVENT_NAME=push BEFORE_SHA="$before" AFTER_SHA="$after" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "Radius.Data" "$(output_value "$output" affected)" \
        "recipe-only namespace edge fallback"
    assert_eq "0" "$(output_value "$output" recipe_pack_count)" \
        "recipe-only edge fallback pack count"

    # A stable namespace release freezes that namespace on its release channel,
    # while the still-unreleased recipe pack continues to follow edge.
    git -C "$repo" tag "Radius.Data/v0.1.0"
    before="$after"
    echo "# stable namespace update" >>"$repo/Data/widgets/widget.yaml"
    echo "// still edge" >>"$repo/recipe-packs/kubernetes/default-recipepack.bicep"
    git -C "$repo" commit -q -am "update after namespace release"
    after="$(git -C "$repo" rev-parse HEAD)"
    : >"$output"

    REPO_ROOT="$repo" EVENT_NAME=push BEFORE_SHA="$before" AFTER_SHA="$after" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "0" "$(output_value "$output" namespace_count)" \
        "stable namespace edge fallback count"
    assert_eq "kubernetes" "$(output_value "$output" affected_recipe_packs)" \
        "unreleased recipe pack edge fallback"

    # Once both units have stable releases, pushes no longer notify Radius.
    git -C "$repo" tag "recipe-pack/kubernetes/v0.1.0"
    before="$after"
    echo "# stable update" >>"$repo/Data/widgets/widget.yaml"
    echo "// stable update" >>"$repo/recipe-packs/kubernetes/default-recipepack.bicep"
    git -C "$repo" commit -q -am "update stable units"
    after="$(git -C "$repo" rev-parse HEAD)"
    : >"$output"

    REPO_ROOT="$repo" EVENT_NAME=push BEFORE_SHA="$before" AFTER_SHA="$after" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "0" "$(output_value "$output" unit_count)" "stable units edge fallback count"
    assert_eq "stable-release-exists" "$(output_value "$output" reason)" \
        "stable units edge fallback reason"
}

test_edge_fallback_push_transitions() {
    local repo="$TEST_ROOT/edge-transitions" output="$TEST_ROOT/edge-transitions.out"
    local before after
    create_repo "$repo" "Data"

    # Deleting the last manifest still identifies the old namespace from the
    # before side of the diff.
    before="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" rm -q Data/widgets/widget.yaml
    git -C "$repo" commit -q -m "delete Data manifest"
    after="$(git -C "$repo" rev-parse HEAD)"
    REPO_ROOT="$repo" EVENT_NAME=push BEFORE_SHA="$before" AFTER_SHA="$after" \
        GITHUB_OUTPUT="$output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "Radius.Data" "$(output_value "$output" affected)" \
        "deleted namespace edge fallback"

    # A namespace rename advances both the old and new units for downstream
    # pruning and registration.
    local rename_repo="$TEST_ROOT/edge-rename" rename_output="$TEST_ROOT/edge-rename.out"
    create_repo "$rename_repo" "Data"
    before="$(git -C "$rename_repo" rev-parse HEAD)"
    git -C "$rename_repo" mv Data Compute
    sed -i 's/Radius\.Data/Radius.Compute/' "$rename_repo/Compute/widgets/widget.yaml"
    git -C "$rename_repo" add .
    git -C "$rename_repo" commit -q -m "rename Data namespace to Compute"
    after="$(git -C "$rename_repo" rev-parse HEAD)"
    REPO_ROOT="$rename_repo" EVENT_NAME=push BEFORE_SHA="$before" AFTER_SHA="$after" \
        GITHUB_OUTPUT="$rename_output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "Radius.Data,Radius.Compute" "$(output_value "$rename_output" affected)" \
        "renamed namespaces edge fallback"

    # A repository-wide stable tag disables edge fallback for every unit.
    local global_repo="$TEST_ROOT/edge-global-stable" global_output="$TEST_ROOT/edge-global-stable.out"
    create_repo "$global_repo" "Data"
    mkdir -p "$global_repo/recipe-packs/kubernetes"
    echo "extension radius" >"$global_repo/recipe-packs/kubernetes/default-recipepack.bicep"
    git -C "$global_repo" add .
    git -C "$global_repo" commit -q -m "add recipe pack"
    git -C "$global_repo" tag v1.0.0
    before="$(git -C "$global_repo" rev-parse HEAD)"
    echo "# updated" >>"$global_repo/Data/widgets/widget.yaml"
    echo "// updated" >>"$global_repo/recipe-packs/kubernetes/default-recipepack.bicep"
    git -C "$global_repo" commit -q -am "update globally released units"
    after="$(git -C "$global_repo" rev-parse HEAD)"
    REPO_ROOT="$global_repo" EVENT_NAME=push BEFORE_SHA="$before" AFTER_SHA="$after" \
        GITHUB_OUTPUT="$global_output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "0" "$(output_value "$global_output" unit_count)" \
        "repository-wide stable edge fallback count"
    assert_eq "stable-release-exists" "$(output_value "$global_output" reason)" \
        "repository-wide stable edge fallback reason"

    # A force-push checkout may not contain event.before. Recover that commit
    # by SHA when the remote still exposes it, otherwise a deleted namespace
    # would be invisible in the current tree.
    local force_source="$TEST_ROOT/edge-force-source"
    local force_remote="$TEST_ROOT/edge-force-remote.git"
    local force_clone="$TEST_ROOT/edge-force-clone"
    local force_output="$TEST_ROOT/edge-force.out"
    create_repo "$force_source" "Data"
    before="$(git -C "$force_source" rev-parse HEAD)"
    git init -q --bare "$force_remote"
    git -C "$force_remote" config uploadpack.allowAnySHA1InWant true
    git -C "$force_source" remote add origin "$force_remote"
    git -C "$force_source" push -q origin HEAD:main
    git -C "$force_source" rm -q Data/widgets/widget.yaml
    git -C "$force_source" commit -q -m "force-delete Data manifest"
    after="$(git -C "$force_source" rev-parse HEAD)"
    git -C "$force_source" push -q --force origin HEAD:main
    git clone -q --depth 1 --branch main "file://$force_remote" "$force_clone"
    if git -C "$force_clone" cat-file -e "${before}^{commit}" 2>/dev/null; then
        fail "force-push fixture unexpectedly contains event.before"
    fi

    REPO_ROOT="$force_clone" EVENT_NAME=push BEFORE_SHA="$before" AFTER_SHA="$after" \
        GITHUB_OUTPUT="$force_output" bash "$SYNC_SCRIPT" >/dev/null 2>&1
    assert_eq "Radius.Data" "$(output_value "$force_output" affected)" \
        "force-push deleted namespace edge fallback"
}

test_recipe_publication_requires_main() {
    grep -q "github.ref == 'refs/heads/main'" "$NAMESPACE_WORKFLOW" ||
        fail "namespace release can invoke recipe publication outside main"
    grep -q "github.ref == 'refs/heads/main'" "$PUBLISH_WORKFLOW" ||
        fail "recipe publisher can run outside main"
}

test_namespace_release_choices() {
    local discovered choices
    discovered="$(bash "$LIST_NAMESPACES_SCRIPT")"
    choices="$(sed -nE 's/^[[:space:]]+- (Radius\.[A-Za-z0-9._-]+)$/\1/p' "$NAMESPACE_WORKFLOW")"
    assert_eq "$discovered" "$choices" "namespace release choices"
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
    # A first release publishes the whole scope, so reporting "0 files" would
    # contradict the `changed=true` it just emitted.
    assert_eq "1" "$(output_value "$output" count)" "unreleased namespace file count"

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

    # A baseline this checkout cannot resolve fails open, and the count still
    # describes the release scope instead of claiming nothing changed. The tag
    # points at a blob, which stands in for any baseline that will not peel to a
    # commit (shallow clone, deleted or unfetched tag).
    local broken="$TEST_ROOT/changes-unreachable" broken_output="$TEST_ROOT/changes-unreachable.out" blob
    create_repo "$broken" "Data"
    blob="$(git -C "$broken" hash-object -w --stdin <<<"not a commit")"
    git -C "$broken" update-ref "refs/tags/Radius.Data/v0.1.0" "$blob"
    detect_changes "$broken" "$broken_output" NAMESPACE Radius.Data
    assert_eq "true" "$(output_value "$broken_output" changed)" "unreachable baseline changed"
    assert_eq "previous-release-unreachable" "$(output_value "$broken_output" reason)" "unreachable baseline reason"
    assert_eq "1" "$(output_value "$broken_output" count)" "unreachable baseline file count"
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

    for bad in v0.51.0 01.2.3 1.02.3 1.2.03 1.2 1.2.3-rc.01 "edge latest"; do
        if COMMIT_SHA="$sha" RELEASE_VERSION="$bad" bash "$TAGS_SCRIPT" >/dev/null 2>&1; then
            fail "invalid recipe release version '$bad' was accepted"
        fi
    done
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
test_release_notification_guards
test_edge_fallback_until_stable_release
test_edge_fallback_push_transitions
test_recipe_publication_requires_main
test_namespace_release_choices
test_prerelease_labels
test_recipe_pack_versioning
test_recipe_pack_bundle
test_recipe_pack_release_is_synced
test_repo_wide_release_covers_all_units
test_release_change_detection
test_recipe_tags
echo "Release automation tests passed"
