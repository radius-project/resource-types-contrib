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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-deploy-all-packs-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repo"
mkdir -p "$FIXTURE_ROOT/recipe-packs/kubernetes" "$FIXTURE_ROOT/recipe-packs/azure-aks" "$FIXTURE_ROOT/recipe-packs/azure-aci" "$TEST_ROOT/bin"

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
param aciContainerRecipeSource string = 'ghcr.io/radius-project/azure-aci-recipes/containers:latest'
param aciContainerRecipePlainHttp bool = false
resource azureAciRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aci'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: aciContainerRecipeSource
        plainHttp: aciContainerRecipePlainHttp
      }
    }
  }
}
EOF
mkdir -p "$FIXTURE_ROOT/Compute/containers/recipes/azure/bicep"
touch "$FIXTURE_ROOT/Compute/containers/recipes/azure/bicep/Current--ACI.bicep"

export CALL_LOG="$TEST_ROOT/calls"
export PARAMETER_FILE_LOG="$TEST_ROOT/parameter-files"
: >"$CALL_LOG"
cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
set -euo pipefail
args=("$@")
for i in "${!args[@]}"; do
    if [[ "${args[i]}" == @* ]]; then
        parameter_file="${args[i]#@}"
        jq -e '.parameters == {
            aciContainerRecipeSource: {value: "reciperegistry:5000/radius-recipes/compute/containers/azure/bicep/current-aci:latest"},
            aciContainerRecipePlainHttp: {value: true}
        }' "$parameter_file" >/dev/null || {
            echo "Expected a string ACI source and Boolean plainHttp in the parameter file." >&2
            exit 1
        }
        realpath "$parameter_file" >>"$PARAMETER_FILE_LOG"
        args[i]='@aci-parameters.json'
    fi
done
echo "rad ${args[*]}" >>"$CALL_LOG"
if [[ -n "${RAD_SIGNAL:-}" ]]; then
    kill -s "$RAD_SIGNAL" "$PPID"
fi
exit "${RAD_EXIT_CODE:-0}"
EOF
chmod +x "$TEST_ROOT/bin/rad"

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

assert_parameter_cleanup() {
    [[ -s "$PARAMETER_FILE_LOG" ]] || fail "ACI deployment must use a parameter file"
    while IFS= read -r parameter_file; do
        [[ ! -e "${parameter_file%/*}" ]] || fail "ACI parameter directory must be cleaned up"
    done <"$PARAMETER_FILE_LOG"
}

# --- kubernetes group: one pack, no required params, name != dir id --------
: >"$CALL_LOG"
run_deploy kubernetes test-env test-rg
expected="rad deploy $FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep --group test-rg --environment test-env
rad env update test-env --recipe-packs default"
diff -u <(echo "$expected") "$CALL_LOG" || fail "kubernetes group deploy calls did not match"

# --- azure group: only the ACI container source uses the checkout ----------
: >"$CALL_LOG"
run_deploy azure test-env test-rg
expected="rad deploy $FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep --group test-rg --environment test-env --parameters @aci-parameters.json
rad env update test-env --recipe-packs azure-aci
rad deploy $FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep --group test-rg --environment test-env --parameters routesGatewayName=validation-gateway --parameters containerImagesRegistry=localhost:5000
rad env update test-env --recipe-packs azure-aks"
diff -u <(echo "$expected") "$CALL_LOG" || fail "azure group deploy calls did not match"
assert_parameter_cleanup

for failure in deploy INT TERM; do
    : >"$CALL_LOG"
    : >"$PARAMETER_FILE_LOG"
    if [[ "$failure" == deploy ]]; then
        if RAD_EXIT_CODE=1 run_deploy azure test-env test-rg; then
            fail "ACI deployment failure must fail the script"
        fi
    else
        if RAD_SIGNAL="$failure" run_deploy azure test-env test-rg; then
            fail "signal $failure must fail the script"
        fi
    fi
    assert_parameter_cleanup
    if grep -q '^rad env update' "$CALL_LOG"; then
        fail "a failed or interrupted ACI deployment must not activate a pack"
    fi
done

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

# Missing or ambiguous checkout recipes must not select a stale artifact.
for recipe_count in 0 2; do
    if [[ "$recipe_count" == 0 ]]; then
        rm "$FIXTURE_ROOT/Compute/containers/recipes/azure/bicep/Current--ACI.bicep"
    else
        touch "$FIXTURE_ROOT/Compute/containers/recipes/azure/bicep/"{first,second}.bicep
    fi
    if run_deploy azure; then
        fail "$recipe_count ACI recipes must fail before deployment"
    fi
    [[ -s "$CALL_LOG" ]] && fail "invalid ACI recipe selection must not invoke rad"
done

cp "$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" "$FIXTURE_ROOT/recipe-packs/kubernetes/second.bicep"
if run_deploy kubernetes; then
    fail "multiple templates must not silently skip the second file"
fi
[[ -s "$CALL_LOG" ]] && fail "ambiguous templates must fail before deployment"

echo "Deploy all checked-in recipe packs tests passed"
