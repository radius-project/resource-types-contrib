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
if [[ "$1" == deploy ]]; then
    if [[ -n "${CAPTURE_DIR:-}" ]]; then
        cp "$2" "$CAPTURE_DIR/$(basename "$2")"
    fi
    exit "${RAD_DEPLOY_EXIT_CODE:-${RAD_EXIT_CODE:-0}}"
fi
exit "${RAD_EXIT_CODE:-0}"
EOF
chmod +x "$TEST_ROOT/bin/rad"

run_deploy() {
    (
        export RTC_REPO_ROOT="$FIXTURE_ROOT"
        PATH="$TEST_ROOT/bin:$PATH"
        unset RTC_LIB_NAMESPACES_SOURCED RTC_LIB_RECIPE_PACKS_SOURCED
        cd "$FIXTURE_ROOT"
        "$REPO_ROOT/.github/scripts/deploy-all-checked-in-recipe-packs.sh" "$@"
    )
}

fail() {
    echo "FAIL: $1" >&2
    cat "$CALL_LOG" >&2
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

# Local mode builds each repository-owned entry, including Kubernetes recipes
# used by Azure packs. It must not regenerate or discard the pack mappings.
cat >"$TEST_ROOT/bin/curl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TEST_ROOT/bin/curl"
mkdir -p "$FIXTURE_ROOT/Compute/containers/recipes/azure/bicep" \
    "$FIXTURE_ROOT/Compute/routes/recipes/kubernetes/bicep" "$TEST_ROOT/captured"
printf '%s\n' '// current ACI source' >"$FIXTURE_ROOT/Compute/containers/recipes/azure/bicep/azure-containers.bicep"
printf '%s\n' '// current Kubernetes source' >"$FIXTURE_ROOT/Compute/routes/recipes/kubernetes/bicep/kubernetes-routes.bicep"
cat >"$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" <<'EOF'
extension radius
resource pack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aci'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        plainHttp: false
        source: 'ghcr.io/radius-project/azure-aci-recipes/containers:latest'
        parameters: {
          setting: { source: 'keep-this-nested-source' }
        }
        outputs: { hosts: 'hosts' }
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/db-for-postgre-sql/flexible-server:0.15.2'
        parameters: {
          configurations: [
            {
              source: 'user-override'
              value: '{{context.resource.properties.tls == "optional" ? "OFF" : "ON"}}'
            }
          ]
        }
        outputs: { host: 'fqdn' }
      }
    }
  }
}
EOF
cat >"$FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep" <<'EOF'
extension radius
param routesGatewayName string
resource pack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aks'
  properties: {
    recipes: {
      'Radius.Compute/routes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/routes:old-release'
        plainHttp: false
        parameters: {
          gatewayName: routesGatewayName
          source: 'keep-this-source'
        }
      }
    }
  }
}
EOF
cp "$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" "$TEST_ROOT/original-aci.bicep"
cp "$FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep" "$TEST_ROOT/original-aks.bicep"
: >"$CALL_LOG"
CAPTURE_DIR="$TEST_ROOT/captured" RECIPE_PACK_USE_LOCAL_RECIPES=true run_deploy azure test-env test-rg
grep -Fq "rad bicep publish --file $FIXTURE_ROOT/Compute/containers/recipes/azure/bicep/azure-containers.bicep --target br:localhost:5000/radius-recipes/compute/containers/azure/bicep/azure-containers:latest --plain-http" "$CALL_LOG" ||
    fail "ACI source must be built from the checkout"
grep -Fq "rad bicep publish --file $FIXTURE_ROOT/Compute/routes/recipes/kubernetes/bicep/kubernetes-routes.bicep --target br:localhost:5000/radius-recipes/compute/routes/kubernetes/bicep/kubernetes-routes:latest --plain-http" "$CALL_LOG" ||
    fail "Azure packs must build their Kubernetes recipe dependencies"
[[ "$(grep -c '^rad bicep publish ' "$CALL_LOG")" == 2 ]] || fail "external modules must not be built"
grep -q -- '--parameters routesGatewayName=validation-gateway' "$CALL_LOG" ||
    fail "staging must preserve required pack parameters"
for pack in aci aks; do
    captured="$(find "$TEST_ROOT/captured" -name "azure-$pack.local-*.bicep")"
    [[ -f "$captured" ]] || fail "staged $pack template was not deployed"
    if [[ "$pack" == aci ]]; then
        replacement='reciperegistry:5000/radius-recipes/compute/containers/azure/bicep/azure-containers:latest'
    else
        replacement='reciperegistry:5000/radius-recipes/compute/routes/kubernetes/bicep/kubernetes-routes:latest'
    fi
    sed -e '/^        plainHttp: false$/d' \
        -e "s|ghcr.io/radius-project/[^']*|$replacement|" \
        -e "/source: 'reciperegistry:/a\\        plainHttp: true" \
        "$TEST_ROOT/original-$pack.bicep" >"$TEST_ROOT/expected-$pack.bicep"
    diff -u "$TEST_ROOT/expected-$pack.bicep" "$captured" ||
        fail "local mode must preserve everything except the owned source and transport"
    cmp "$TEST_ROOT/original-$pack.bicep" "$FIXTURE_ROOT/recipe-packs/azure-$pack/azure-$pack.bicep" ||
        fail "checked-in pack must remain unchanged"
done
[[ -z "$(find "$FIXTURE_ROOT/recipe-packs" -name '*.local-*.bicep')" ]] ||
    fail "staged templates must be removed after deployment"

# A pack with no owned recipes must remain unchanged.
: >"$CALL_LOG"
CAPTURE_DIR="$TEST_ROOT/captured" RECIPE_PACK_USE_LOCAL_RECIPES=true run_deploy kubernetes
captured="$(find "$TEST_ROOT/captured" -name 'default.local-*.bicep')"
cmp "$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" "$captured" ||
    fail "empty source mappings must not change a pack"
if grep -q '^rad bicep publish ' "$CALL_LOG"; then
    fail "a pack without owned recipes must not build anything"
fi

for failure in build deploy missing ambiguous source artifact expression interpolation missing-source duplicate-source inline-entry; do
    : >"$CALL_LOG"
    case "$failure" in
        missing) mv "$FIXTURE_ROOT/Compute/containers/recipes/azure/bicep/azure-containers.bicep" "$TEST_ROOT/held.bicep" ;;
        ambiguous) touch "$FIXTURE_ROOT/Compute/containers/recipes/azure/bicep/second.bicep" ;;
        source) sed -i 's|azure-aci-recipes/containers:|unknown-recipes/containers:|' "$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" ;;
        artifact) sed -i 's|azure-aci-recipes/containers:|azure-aci-recipes/wrong-type:|' "$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" ;;
        expression) sed -i "1a var containerRecipe = 'ghcr.io/radius-project/azure-aci-recipes/containers:latest'" "$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep"
            sed -i "s|source: 'ghcr.io/radius-project/azure-aci-recipes/containers:latest'|source: containerRecipe|" "$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" ;;
        interpolation) sed -i 's|containers:latest|containers:${recipeTag}|' "$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" ;;
        missing-source) sed -i '/source:.*azure-aci-recipes/d' "$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" ;;
        duplicate-source) sed -i '/source:.*azure-aci-recipes/p' "$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" ;;
        inline-entry) sed -i "s|'Radius.Compute/containers': {|'Radius.Compute/containers': { source: containerRecipe|" "$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" ;;
    esac
    build_status=0
    deploy_status=0
    [[ "$failure" == build ]] && build_status=1
    [[ "$failure" == deploy ]] && deploy_status=1
    if RAD_EXIT_CODE="$build_status" RAD_DEPLOY_EXIT_CODE="$deploy_status" \
        RECIPE_PACK_USE_LOCAL_RECIPES=true run_deploy azure; then
        fail "local recipe $failure failure must stop the test"
    fi
    if grep -q '^rad env update ' "$CALL_LOG"; then
        fail "failed local staging or deployment must not activate a pack"
    fi
    if [[ "$failure" != deploy ]] && grep -q '^rad deploy ' "$CALL_LOG"; then
        fail "failed local preparation must not fall back to published recipes"
    fi
    [[ -z "$(find "$FIXTURE_ROOT/recipe-packs" -name '*.local-*.bicep')" ]] ||
        fail "failed local tests must remove staged templates"
    case "$failure" in
        missing) mv "$TEST_ROOT/held.bicep" "$FIXTURE_ROOT/Compute/containers/recipes/azure/bicep/azure-containers.bicep" ;;
        ambiguous) rm "$FIXTURE_ROOT/Compute/containers/recipes/azure/bicep/second.bicep" ;;
        source | artifact | expression | interpolation | missing-source | duplicate-source | inline-entry)
            cp "$TEST_ROOT/original-aci.bicep" "$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" ;;
    esac
done

# Exercise every real pack and compare staged pull targets with publish targets.
while IFS= read -r template; do
    : >"$CALL_LOG"
    output="$TEST_ROOT/real-pack.bicep"
    RTC_REPO_ROOT="$REPO_ROOT" PATH="$TEST_ROOT/bin:$PATH" \
        bash "$REPO_ROOT/.github/scripts/prepare-local-recipe-pack.sh" "$template" "$output" >/dev/null
    if grep -q "source: 'ghcr.io/radius-project/" "$output"; then
        fail "real pack retained a published repository recipe"
    fi
    sed -nE "s|^[[:space:]]*source: '(reciperegistry:5000/[^']+)'.*|\1|p" "$output" |
        sort >"$TEST_ROOT/pull-targets"
    sed -nE 's|^rad bicep publish .* --target br:localhost:5000/([^ ]+) --plain-http$|reciperegistry:5000/\1|p' "$CALL_LOG" |
        sort >"$TEST_ROOT/publish-targets"
    diff -u "$TEST_ROOT/publish-targets" "$TEST_ROOT/pull-targets" ||
        fail "pack sources must exactly match the recipes built from this checkout"
    grep "source: 'mcr.microsoft.com/" "$template" >"$TEST_ROOT/original-external" || true
    grep "source: 'mcr.microsoft.com/" "$output" >"$TEST_ROOT/staged-external" || true
    cmp "$TEST_ROOT/original-external" "$TEST_ROOT/staged-external" ||
        fail "external module versions must remain unchanged"
done < <(find "$REPO_ROOT/recipe-packs" -name '*.bicep' -type f | sort)

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
