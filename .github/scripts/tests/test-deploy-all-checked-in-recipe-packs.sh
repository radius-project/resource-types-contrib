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
exit "${RAD_EXIT_CODE:-0}"
EOF
chmod +x "$TEST_ROOT/bin/rad"

run_deploy() {
    (
        RTC_REPO_ROOT="$FIXTURE_ROOT"
        PATH="$TEST_ROOT/bin:$PATH"
        unset RTC_LIB_NAMESPACES_SOURCED RTC_LIB_RECIPE_PACKS_SOURCED
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
rad env update test-env --recipe-packs default --preview"
diff -u <(echo "$expected") "$CALL_LOG" || fail "kubernetes group deploy calls did not match"

# --- azure group: two packs, one with required params ----------------------
: >"$CALL_LOG"
run_deploy azure test-env test-rg
expected="rad deploy $FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep --group test-rg --environment test-env
rad env update test-env --recipe-packs azure-aci --preview
rad deploy $FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep --group test-rg --environment test-env --parameters routesGatewayName=validation-gateway --parameters containerImagesRegistry=localhost:5000
rad env update test-env --recipe-packs azure-aks --preview"
diff -u <(echo "$expected") "$CALL_LOG" || fail "azure group deploy calls did not match"

# The base pull_request_target workflow still calls the legacy entry point.
: >"$CALL_LOG"
(
    cd "$FIXTURE_ROOT"
    PATH="$TEST_ROOT/bin:$PATH" "$REPO_ROOT/.github/scripts/deploy-checked-in-azure-recipe-pack.sh"
)
expected="rad deploy recipe-packs/azure-aks/azure-aks.bicep --group default --environment default --parameters routesGatewayName=validation-gateway --parameters containerImagesRegistry=localhost:5000
rad env update default --recipe-packs azure-aks --preview"
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

cp "$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" "$FIXTURE_ROOT/recipe-packs/kubernetes/second.bicep"
if run_deploy kubernetes; then
    fail "multiple templates must not silently skip the second file"
fi
[[ -s "$CALL_LOG" ]] && fail "ambiguous templates must fail before deployment"

echo "Deploy all checked-in recipe packs tests passed"
