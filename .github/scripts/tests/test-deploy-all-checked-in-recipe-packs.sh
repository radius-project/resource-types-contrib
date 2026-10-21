#!/bin/bash

# ------------------------------------------------------------
# Copyright 2026 The Radius Authors.
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

# Tests deploy-all-checked-in-recipe-packs.sh against a fixture repo with two
# packs on the same platform group (one with required parameters, one
# without, and one whose declared pack name differs from its directory name),
# asserting the exact `rad` invocations.

set -euo pipefail

# Exercise local and GitHub Actions defaults independently of the test runner.
unset RECIPE_PACK_USE_LOCAL_RECIPES GITHUB_ACTIONS

command -v jq >/dev/null || { echo "Error: jq is required for these tests." >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-deploy-all-packs-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
export TMPDIR="$TEST_ROOT/scratch"
mkdir "$TMPDIR"

FIXTURE_ROOT="$TEST_ROOT/repo"
mkdir -p "$FIXTURE_ROOT/recipe-packs/kubernetes" "$FIXTURE_ROOT/recipe-packs/azure-aks" "$FIXTURE_ROOT/recipe-packs/azure-aci" "$TEST_ROOT/bin"
export EXPECTED_BICEP_CONFIG_DIR="$FIXTURE_ROOT"
printf '%s\n' '{"extensions":{"radius":"br:biceptypes.azurecr.io/radius:latest","widgets":"./widgets-extension.tgz"}}' >"$FIXTURE_ROOT/bicepconfig.json"
touch "$FIXTURE_ROOT/widgets-extension.tgz"

# Mirrors the real repo: the kubernetes pack's declared name is 'default',
# not 'kubernetes'; it has no required parameters.
cat >"$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" <<'EOF'
resource kubernetesRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'default'
  properties: {
    recipes: {}
  }
}
EOF

cat >"$FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep" <<'EOF'
param routesGatewayName string
param containerImagesRegistry string
param routesGatewayNamespace string = 'default'
resource azureAksRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aks'
  properties: {
    recipes: {}
  }
}
EOF

cat >"$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" <<'EOF'
resource azureAciRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aci'
  properties: {
    recipes: {}
  }
}
EOF

export CALL_LOG="$TEST_ROOT/calls"
: >"$CALL_LOG"
cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
echo "rad $*" >>"$CALL_LOG"
if [[ "$1" == deploy ]]; then
    # Approximate ancestor config discovery without requiring a Bicep compiler.
    config_dir="$(cd "$(dirname "$2")" && pwd)"
    while [[ "$config_dir" == "$EXPECTED_BICEP_CONFIG_DIR/"* && ! -f "$config_dir/bicepconfig.json" ]]; do
        config_dir="$(dirname "$config_dir")"
    done
    extension="$(jq -r '.extensions.widgets' "$config_dir/bicepconfig.json")"
    if [[ "$config_dir" != "$EXPECTED_BICEP_CONFIG_DIR" && "$extension" != /* ]]; then
        echo "FAIL: relocated config must use absolute local extension paths" >&2
        exit 1
    fi
    [[ "$extension" == /* ]] || extension="$config_dir/$extension"
    if [[ ! -f "$extension" ]] ||
        [[ "$(jq -r '.extensions.radius' "$config_dir/bicepconfig.json")" != br:biceptypes.azurecr.io/radius:latest ]]; then
        echo "FAIL: deployed template lost the original Bicep config or relative extension" >&2
        exit 1
    fi
fi
if [[ "$1" == deploy && -n "${DEPLOY_CAPTURE:-}" ]]; then
    capture_name="$(basename "$2")"
    [[ "$capture_name" != default.bicep ]] || capture_name=kubernetes.bicep
    cp "$2" "$DEPLOY_CAPTURE/$capture_name"
fi
exit "${RAD_EXIT_CODE:-0}"
EOF
chmod +x "$TEST_ROOT/bin/rad"
export BUILD_LOG="$TEST_ROOT/builds"
cat >"$TEST_ROOT/bin/make" <<'EOF'
#!/bin/bash
echo "make $*" >>"$BUILD_LOG"
exit "${BUILD_EXIT_CODE:-0}"
EOF
chmod +x "$TEST_ROOT/bin/make"

run_deploy() {
    (
        RTC_REPO_ROOT="$FIXTURE_ROOT"
        PATH="$TEST_ROOT/bin:$PATH"
        unset RTC_LIB_NAMESPACES_SOURCED RTC_LIB_RECIPE_PACKS_SOURCED
        export RTC_REPO_ROOT PATH
        cd "$FIXTURE_ROOT"
        "$REPO_ROOT/.github/scripts/deploy-all-checked-in-recipe-packs.sh" "$@"
    )
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# --- kubernetes group: one pack, no required params, name != dir id --------
: >"$CALL_LOG"
run_deploy kubernetes test-env test-rg
expected="rad deploy $FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep --group test-rg --environment test-env
rad env update test-env --recipe-packs default"
diff -u <(echo "$expected") "$CALL_LOG" || fail "kubernetes group deploy calls did not match"

# --- azure group: two packs, one with required params ----------------------
: >"$CALL_LOG"
run_deploy azure test-env test-rg
expected="rad deploy $FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep --group test-rg --environment test-env
rad env update test-env --recipe-packs azure-aci
rad deploy $FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep --group test-rg --environment test-env --parameters routesGatewayName=validation-gateway --parameters containerImagesRegistry=localhost:5000
rad env update test-env --recipe-packs azure-aks"
diff -u <(echo "$expected") "$CALL_LOG" || fail "azure group deploy calls did not match"

# The base pull_request_target workflow still calls the legacy entry point.
: >"$CALL_LOG"
(
    cd "$FIXTURE_ROOT"
    PATH="$TEST_ROOT/bin:$PATH" "$REPO_ROOT/.github/scripts/deploy-checked-in-azure-recipe-pack.sh"
)
expected="rad deploy recipe-packs/azure-aks/azure-aks.bicep --group default --environment default --parameters routesGatewayName=validation-gateway --parameters containerImagesRegistry=localhost:5000
rad env update default --recipe-packs azure-aks"
diff -u <(echo "$expected") "$CALL_LOG" || fail "legacy Azure deploy calls did not match"

# --- deployment failures must prevent activation -------------------------
: >"$CALL_LOG"
if RAD_EXIT_CODE=1 run_deploy kubernetes test-env test-rg; then
    fail "rad deployment failure must fail the script"
fi
if grep -q '^rad env update' "$CALL_LOG"; then
    fail "a failed deployment must not activate a pack"
fi

# --- unknown platform group: fail before invoking rad ---------------------
: >"$CALL_LOG"
if run_deploy made-up-group test-env test-rg; then
    fail "unknown platform group must fail"
fi
[[ -s "$CALL_LOG" ]] && fail "made-up platform group should not invoke rad at all"

# A pack that sorts before existing packs must not turn failure into a skip.
mkdir -p "$FIXTURE_ROOT/recipe-packs/aaa-unmapped"
cp "$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" "$FIXTURE_ROOT/recipe-packs/aaa-unmapped/pack.bicep"
if run_deploy azure; then
    fail "an unmapped pack must fail discovery"
fi
[[ -s "$CALL_LOG" ]] && fail "discovery failure must occur before any deployment"
rm "$FIXTURE_ROOT/recipe-packs/aaa-unmapped/pack.bicep"

# --- local mode rewrites only repo-owned entry sources --------------------
mkdir -p "$FIXTURE_ROOT/Compute/containers/recipes/"{kubernetes,azure}/bicep \
    "$FIXTURE_ROOT/Data/widgets/recipes/kubernetes/bicep" "$TEST_ROOT/captured" "$TEST_ROOT/original"
touch "$FIXTURE_ROOT/Compute/containers/recipes/kubernetes/bicep/aks.bicep" \
    "$FIXTURE_ROOT/Compute/containers/recipes/azure/bicep/aci.bicep" \
    "$FIXTURE_ROOT/Data/widgets/recipes/kubernetes/bicep/Widget--Recipe.bicep"
cat >"$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" <<'EOF'
param location string = 'westus3'
resource kubernetesRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'default'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containers:latest' // retained
        plainHttp: false
        parameters: {
          location: location
        }
        outputs: {
          host: 'properties.host'
        }
      }
      'Radius.Data/widgets': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/widgets:latest'
      }
      'Radius.Data/direct': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/test:1.0.0'
        plainHttp: false
        parameters: {
          configurations: [
            {
              source: 'ghcr.io/radius-project/kube-recipes/nested-parameter:latest'
            }
          ]
        }
      }
      'Radius.Data/external': {
        kind: 'bicep'
        source: 'ghcr.io/another-org/kube-recipes/external:latest'
      }
    }
  }
}
output packName string = kubernetesRecipePack.name
EOF
cat >"$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" <<'EOF'
resource azureAciRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aci'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-aci-recipes/containers:latest'
      }
    }
  }
}
EOF
# The AKS pack combines Azure direct modules and Kubernetes-backed recipes.
cp "$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" "$FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep"
sed -i "s/name: 'default'/name: 'azure-aks'/" "$FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep"
sed -i '1i param routesGatewayName string\nparam containerImagesRegistry string' \
    "$FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep"
for pack_id in kubernetes azure-aci azure-aks; do
    cp "$FIXTURE_ROOT/recipe-packs/$pack_id/"*.bicep "$TEST_ROOT/original/$pack_id.bicep"
done
export DEPLOY_CAPTURE="$TEST_ROOT/captured"
cp "$FIXTURE_ROOT/bicepconfig.json" "$TEST_ROOT/original/bicepconfig.json"

assert_sources_unchanged_and_clean() {
    local pack_id template
    for pack_id in kubernetes azure-aci azure-aks; do
        case "$pack_id" in
            kubernetes) template=default ;;
            *) template="$pack_id" ;;
        esac
        diff -u "$TEST_ROOT/original/$pack_id.bicep" "$FIXTURE_ROOT/recipe-packs/$pack_id/$template.bicep" ||
            fail "local mode changed checked-in $pack_id pack"
    done
    diff -u "$TEST_ROOT/original/bicepconfig.json" "$FIXTURE_ROOT/bicepconfig.json" ||
        fail "local mode must not change the original Bicep config"
    [[ -z "$(find "$TMPDIR" -maxdepth 1 -name 'rtc-recipe-packs-*')" ]] ||
        fail "temporary pack copies must be cleaned up"
}

for mode in unset false true actions-auto actions-false; do
    : >"$CALL_LOG"
    : >"$BUILD_LOG"
    (
        unset RECIPE_PACK_USE_LOCAL_RECIPES GITHUB_ACTIONS
        case "$mode" in
            actions-auto) export GITHUB_ACTIONS=true ;;
            actions-false) export GITHUB_ACTIONS=true RECIPE_PACK_USE_LOCAL_RECIPES=false ;;
            unset) ;;
            *) export RECIPE_PACK_USE_LOCAL_RECIPES="$mode" ;;
        esac
        run_deploy kubernetes test-env test-rg
        run_deploy azure test-env test-rg
    ) 2>"$TEST_ROOT/rewrite.log"
    for pack_id in kubernetes azure-aci azure-aks; do
        if [[ "$mode" == true || "$mode" == actions-auto ]]; then
            # Only the selected source and its transport flag may differ.
            sed \
                -e "s@ghcr.io/radius-project/kube-recipes/containers:latest@reciperegistry:5000/radius-recipes/compute/containers/kubernetes/bicep/aks:latest@" \
                -e "s@ghcr.io/radius-project/kube-recipes/widgets:latest@reciperegistry:5000/radius-recipes/data/widgets/kubernetes/bicep/widget-recipe:latest@" \
                -e "s@ghcr.io/radius-project/azure-aci-recipes/containers:latest@reciperegistry:5000/radius-recipes/compute/containers/azure/bicep/aci:latest@" \
                -e '/source:.*reciperegistry:5000/{n; /plainHttp: false/d;}' \
                "$TEST_ROOT/original/$pack_id.bicep" |
                sed '/source:.*reciperegistry:5000/a\        plainHttp: true' >"$TEST_ROOT/expected.bicep"
        else
            cp "$TEST_ROOT/original/$pack_id.bicep" "$TEST_ROOT/expected.bicep"
        fi
        diff -u "$TEST_ROOT/expected.bicep" "$DEPLOY_CAPTURE/$pack_id.bicep" ||
            fail "$mode mode did not preserve the expected $pack_id template"
    done
    [[ "$(grep -c '^rad env update' "$CALL_LOG")" == 3 ]] || fail "each pack must still activate"
    grep -Fq -- '--parameters routesGatewayName=validation-gateway --parameters containerImagesRegistry=localhost:5000' "$CALL_LOG" ||
        fail "required parameters must be preserved in every mode"
    if [[ "$mode" == true || "$mode" == actions-auto ]]; then
        [[ "$(grep -c '^==> Local recipe ' "$TEST_ROOT/rewrite.log")" == 5 ]] ||
            fail "local mode must log every substituted entry"
        grep -Fq "'ghcr.io/radius-project/azure-aci-recipes/containers:latest' -> 'reciperegistry:5000/radius-recipes/compute/containers/azure/bicep/aci:latest'" \
            "$TEST_ROOT/rewrite.log" || fail "ACI substitution log must show both sources"
        expected_builds="make -s -C $FIXTURE_ROOT build-bicep-recipe RECIPE_PATH=$FIXTURE_ROOT/Compute/containers/recipes/kubernetes/bicep/aks.bicep
make -s -C $FIXTURE_ROOT build-bicep-recipe RECIPE_PATH=$FIXTURE_ROOT/Data/widgets/recipes/kubernetes/bicep/Widget--Recipe.bicep
make -s -C $FIXTURE_ROOT build-bicep-recipe RECIPE_PATH=$FIXTURE_ROOT/Compute/containers/recipes/azure/bicep/aci.bicep
make -s -C $FIXTURE_ROOT build-bicep-recipe RECIPE_PATH=$FIXTURE_ROOT/Compute/containers/recipes/kubernetes/bicep/aks.bicep
make -s -C $FIXTURE_ROOT build-bicep-recipe RECIPE_PATH=$FIXTURE_ROOT/Data/widgets/recipes/kubernetes/bicep/Widget--Recipe.bicep"
        diff -u <(echo "$expected_builds") "$BUILD_LOG" ||
            fail "local mode must publish exactly every selected checkout recipe"
    else
        [[ ! -s "$TEST_ROOT/rewrite.log" ]] || fail "default mode must not log substitutions"
        [[ ! -s "$BUILD_LOG" ]] || fail "published mode must not build recipes"
    fi
    assert_sources_unchanged_and_clean
done

assert_local_failure() {
    : >"$CALL_LOG"
    : >"$BUILD_LOG"
    if RECIPE_PACK_USE_LOCAL_RECIPES=true run_deploy kubernetes; then
        fail "$1 must fail local mode"
    fi
    [[ ! -s "$CALL_LOG" ]] || fail "$1 must fail before invoking rad"
    [[ ! -s "$BUILD_LOG" ]] || fail "$1 must fail before publishing recipes"
    assert_sources_unchanged_and_clean
}

cp "$TEST_ROOT/original/kubernetes.bicep" "$TEST_ROOT/kubernetes-base.bicep"
for suffix in ':Test_Tag-1' "@sha256:$(printf '%064d' 0)"; do
    sed "s|kube-recipes/containers:latest|kube-recipes/containers$suffix|" \
        "$TEST_ROOT/kubernetes-base.bicep" >"$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep"
    cp "$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" "$TEST_ROOT/original/kubernetes.bicep"
    RECIPE_PACK_USE_LOCAL_RECIPES=true run_deploy kubernetes >/dev/null 2>"$TEST_ROOT/rewrite.log"
    grep -Fq "'ghcr.io/radius-project/kube-recipes/containers$suffix' -> 'reciperegistry:5000/radius-recipes/compute/containers/kubernetes/bicep/aks:latest'" \
        "$TEST_ROOT/rewrite.log" || fail "valid tags and digest references must resolve locally"
    assert_sources_unchanged_and_clean
done
for image in 'secrets:latest' 'nested/containers:latest' 'containers@sha256:invalid'; do
    sed "s|kube-recipes/containers:latest|kube-recipes/$image|" \
        "$TEST_ROOT/kubernetes-base.bicep" >"$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep"
    cp "$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" "$TEST_ROOT/original/kubernetes.bicep"
    assert_local_failure "incorrect owned image '$image'"
done
cp "$TEST_ROOT/kubernetes-base.bicep" "$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep"
cp "$TEST_ROOT/kubernetes-base.bicep" "$TEST_ROOT/original/kubernetes.bicep"

mv "$FIXTURE_ROOT/Compute/containers/recipes/kubernetes/bicep/aks.bicep" "$TEST_ROOT/aks.bicep"
assert_local_failure "missing recipe"
mv "$TEST_ROOT/aks.bicep" "$FIXTURE_ROOT/Compute/containers/recipes/kubernetes/bicep/aks.bicep"
touch "$FIXTURE_ROOT/Compute/containers/recipes/kubernetes/bicep/second.bicep"
assert_local_failure "ambiguous recipes"
rm "$FIXTURE_ROOT/Compute/containers/recipes/kubernetes/bicep/second.bicep"
mv "$FIXTURE_ROOT/Compute/containers/recipes/kubernetes" "$TEST_ROOT/kubernetes-recipes"
assert_local_failure "missing recipe directory"
mv "$TEST_ROOT/kubernetes-recipes" "$FIXTURE_ROOT/Compute/containers/recipes/kubernetes"
sed -i 's@radius-project/kube-recipes/containers@radius-project/unknown-recipes/containers@' \
    "$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep"
cp "$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" "$TEST_ROOT/original/kubernetes.bicep"
assert_local_failure "unknown repository-owned registry"

: >"$CALL_LOG"
if RECIPE_PACK_USE_LOCAL_RECIPES=true RAD_EXIT_CODE=1 run_deploy azure; then
    fail "local mode must propagate deployment failure"
fi
grep -q '^rad deploy .*rtc-recipe-packs-' "$CALL_LOG" || fail "failure test must deploy a local copy"
if grep -q '^rad env update' "$CALL_LOG"; then
    fail "failed local deployment must not activate a pack"
fi
assert_sources_unchanged_and_clean
: >"$CALL_LOG"

# Publication failure must fail before deploying the affected pack.
if RECIPE_PACK_USE_LOCAL_RECIPES=true BUILD_EXIT_CODE=1 run_deploy azure; then
    fail "recipe publication failure must fail Azure local mode"
fi
if [[ -s "$CALL_LOG" ]]; then
    fail "a pack with unpublished dependencies must not deploy"
fi
assert_sources_unchanged_and_clean
: >"$CALL_LOG"

printf '%s\n' 'invalid json' >"$FIXTURE_ROOT/bicepconfig.json"
if RECIPE_PACK_USE_LOCAL_RECIPES=true run_deploy azure; then
    fail "invalid Bicep configuration must fail local mode"
fi
[[ ! -s "$CALL_LOG" ]] || fail "invalid Bicep configuration must not deploy"
cp "$TEST_ROOT/original/bicepconfig.json" "$FIXTURE_ROOT/bicepconfig.json"
assert_sources_unchanged_and_clean

cp "$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" "$FIXTURE_ROOT/recipe-packs/kubernetes/second.bicep"
if run_deploy kubernetes; then
    fail "multiple templates must not silently skip the second file"
fi
[[ -s "$CALL_LOG" ]] && fail "ambiguous templates must fail before deployment"

echo "Deploy all checked-in recipe packs tests passed (local ACI/AKS sources, checkout publication, base-workflow CI default and explicit override, substitution logs, unchanged metadata, relocated Bicep config/extensions, cleanup)"
