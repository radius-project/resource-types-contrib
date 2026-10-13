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

# Tests test-all-direct-module-recipes.sh against a fixture repo with two
# packs on the same platform group, one of which shares a direct-module gap
# with the other. Each mapping must be tested with its own pack active.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-test-all-direct-module-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repo"
mkdir -p \
    "$FIXTURE_ROOT/recipe-packs/azure-aks" \
    "$FIXTURE_ROOT/recipe-packs/azure-aci" \
    "$FIXTURE_ROOT/recipe-packs/kubernetes" \
    "$FIXTURE_ROOT/Data/redisCaches/test" \
    "$FIXTURE_ROOT/Data/mySqlDatabases/test" \
    "$TEST_ROOT/bin"

cat >"$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" <<'EOF'
resource pack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'default'
  properties: {
    recipes: {}
  }
}
EOF

# redisCaches is a direct-module gap shared by both packs; mySqlDatabases is
# only a gap in azure-aks.
cat >"$FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep" <<'EOF'
resource azureAksRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aks'
  properties: {
    recipes: {
      'Radius.Data/redisCaches': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/cache/redis:0.5.1'
      }
      'Radius.Data/mySqlDatabases': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/db-for-my-sql/flexible-server:0.5.1'
      }
    }
  }
}
EOF

cat >"$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" <<'EOF'
resource azureAciRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aci'
  properties: {
    recipes: {
      'Radius.Data/redisCaches': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/cache/redis:0.5.1'
      }
    }
  }
}
EOF

echo "resource foo 'Radius.Data/redisCaches@2025-08-01-preview' = {}" >"$FIXTURE_ROOT/Data/redisCaches/test/app.bicep"
echo "resource foo 'Radius.Data/mySqlDatabases@2025-08-01-preview' = {}" >"$FIXTURE_ROOT/Data/mySqlDatabases/test/app.bicep"

export CALL_LOG="$TEST_ROOT/calls"
export FAIL_TYPE=""
: >"$CALL_LOG"

# Stand in for test-direct-module-recipe.sh: logs its arguments and exits
# non-zero for the Resource Type directory named in $FAIL_TYPE.
cat >"$TEST_ROOT/bin/test-direct-module-recipe.sh" <<'EOF'
#!/bin/bash
echo "test-direct-module-recipe.sh $*" >>"$CALL_LOG"
[[ "$1" == "$FAIL_TYPE" ]] && exit 1
exit 0
EOF
chmod +x "$TEST_ROOT/bin/test-direct-module-recipe.sh"

cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
echo "rad $*" >>"$CALL_LOG"
exit "${ACTIVATE_EXIT_CODE:-0}"
EOF
chmod +x "$TEST_ROOT/bin/rad"

# The driver resolves the sibling script via its own SCRIPT_DIR, so stand the
# fixture's replacement in for the real one inside a throwaway copy of
# .github/scripts rather than relying on PATH.
SCRIPTS_COPY="$TEST_ROOT/scripts"
cp -r "$REPO_ROOT/.github/scripts" "$SCRIPTS_COPY"
cp "$TEST_ROOT/bin/test-direct-module-recipe.sh" "$SCRIPTS_COPY/test-direct-module-recipe.sh"

run_driver() {
    (
        RTC_REPO_ROOT="$FIXTURE_ROOT"
        export PATH="$TEST_ROOT/bin:$PATH"
        unset RTC_LIB_NAMESPACES_SOURCED RTC_LIB_RECIPE_PACKS_SOURCED
        cd "$FIXTURE_ROOT"
        "$SCRIPTS_COPY/test-all-direct-module-recipes.sh" "$@"
    )
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# --- each pack is activated before its own tests --------------------------
: >"$CALL_LOG"
FAIL_TYPE="" run_driver azure azure-ws azure-env ||
    fail "expected all-pass run to exit 0"
expected="rad env update azure-env --workspace azure-ws --recipe-packs azure-aci --preview
test-direct-module-recipe.sh Data/redisCaches azure-ws azure-env
rad env update azure-env --workspace azure-ws --recipe-packs azure-aks --preview
test-direct-module-recipe.sh Data/redisCaches azure-ws azure-env
test-direct-module-recipe.sh Data/mySqlDatabases azure-ws azure-env"
diff -u <(echo "$expected") "$CALL_LOG" || fail "each pack must be active for all its tests"
grep -q "test-direct-module-recipe.sh Data/mySqlDatabases azure-ws azure-env" "$CALL_LOG" ||
    fail "expected Data/mySqlDatabases to be tested with the given workspace/environment"

# --- a failing gap makes the driver exit non-zero, but still runs the rest -
: >"$CALL_LOG"
if FAIL_TYPE="Data/redisCaches" run_driver azure azure-ws azure-env; then
    fail "expected a failing direct-module test to make the driver exit non-zero"
fi
grep -q "test-direct-module-recipe.sh Data/mySqlDatabases" "$CALL_LOG" ||
    fail "expected the driver to still test the remaining gap after one failure"

# --- activation errors must stop tests from using the previous pack -------
: >"$CALL_LOG"
if ACTIVATE_EXIT_CODE=1 run_driver azure azure-ws azure-env; then
    fail "activation errors must fail the driver"
fi
if grep -q '^test-direct-module-recipe.sh' "$CALL_LOG"; then
    fail "no tests should run after an activation error"
fi

# --- a known pack without direct-module entries needs no test deployment --
: >"$CALL_LOG"
run_driver kubernetes || fail "a pack without direct-module entries should pass"
[[ -s "$CALL_LOG" ]] && fail "no rad or test calls expected for a pack without direct-module entries"

# --- unknown platform groups and unmapped packs must fail -----------------
: >"$CALL_LOG"
if run_driver made-up-group; then
    fail "an unknown platform group must fail"
fi
[[ -s "$CALL_LOG" ]] && fail "no test-direct-module-recipe.sh calls expected for an unmapped platform group"

mkdir -p "$FIXTURE_ROOT/recipe-packs/aaa-unmapped"
cp "$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" "$FIXTURE_ROOT/recipe-packs/aaa-unmapped/pack.bicep"
if run_driver azure; then
    fail "an unmapped pack must fail discovery"
fi
[[ -s "$CALL_LOG" ]] && fail "discovery failure must occur before any rad calls"

echo "Test all direct-module recipes tests passed"
