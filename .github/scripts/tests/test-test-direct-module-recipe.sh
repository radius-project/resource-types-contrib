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

# Tests test-direct-module-recipe.sh against a fixture Resource Type
# directory, using fake `rad`/`jq`/`kubectl` binaries to assert behavior
# without a live Radius environment: successful deploy, failed deploy (no
# recipe unregister -- this script never registered one), missing test file,
# and missing arguments.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-test-direct-module-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repo"
mkdir -p "$FIXTURE_ROOT/Data/mySqlDatabases/test" "$FIXTURE_ROOT/Data/noTestFile" "$TEST_ROOT/bin"

cat >"$FIXTURE_ROOT/Data/mySqlDatabases/test/app.bicep" <<'EOF'
resource mySql 'Radius.Data/mySqlDatabases@2025-08-01-preview' = {
  name: 'testresource'
}
EOF

export CALL_LOG="$TEST_ROOT/calls"
export DEPLOY_EXIT_CODE=0
: >"$CALL_LOG"

cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
echo "rad $*" >>"$CALL_LOG"
case "$1" in
    env)
        echo '{"id":"/planes/radius/local/resourceGroups/default/providers/Applications.Core/environments/azure","properties":{"providers":{"kubernetes":{"namespace":"azure-ns"}}}}'
        ;;
    deploy)
        exit "${DEPLOY_EXIT_CODE:-0}"
        ;;
esac
exit 0
EOF
chmod +x "$TEST_ROOT/bin/rad"

cat >"$TEST_ROOT/bin/jq" <<'EOF'
#!/bin/bash
filter="${2:-$1}"
case "$filter" in
    *".id // \"\""*) echo "/planes/radius/local/resourceGroups/default/providers/Applications.Core/environments/azure" ;;
    *"kubernetes.namespace"*) echo "azure-ns" ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/jq"

cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >>"$CALL_LOG"
EOF
chmod +x "$TEST_ROOT/bin/kubectl"

run_test() {
    (
        PATH="$TEST_ROOT/bin:$PATH"
        cd "$FIXTURE_ROOT"
        "$REPO_ROOT/.github/scripts/test-direct-module-recipe.sh" "$@"
    )
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# --- successful deploy: resolves environment, deploys, asserts, cleans up ---
: >"$CALL_LOG"
DEPLOY_EXIT_CODE=0 run_test Data/mySqlDatabases azure azure ||
    fail "expected successful run to exit 0"
grep -q "rad env show azure --workspace azure" "$CALL_LOG" ||
    fail "expected environment to be resolved"
grep -q "rad deploy Data/mySqlDatabases/test/app.bicep" "$CALL_LOG" ||
    fail "expected test app to be deployed"
grep -q "rad app delete" "$CALL_LOG" ||
    fail "expected test app to be cleaned up on success"
grep -q "rad recipe unregister" "$CALL_LOG" &&
    fail "a direct-module test must never unregister a recipe -- it never registered one"

# --- failed deploy: app/K8s cleanup still runs, no recipe unregister, exit 1
: >"$CALL_LOG"
if DEPLOY_EXIT_CODE=1 run_test Data/mySqlDatabases azure azure; then
    fail "expected failed deploy to exit non-zero"
fi
grep -q "kubectl delete secrets" "$CALL_LOG" ||
    fail "expected K8s cleanup to run after a failed deploy"
grep -q "rad recipe unregister" "$CALL_LOG" &&
    fail "a direct-module test must never unregister a recipe on failure either"

# --- missing test/app.bicep: skipped, exits 0 -------------------------------
: >"$CALL_LOG"
run_test Data/noTestFile azure azure ||
    fail "expected a missing test file to be skipped (exit 0), not fail"
[[ -s "$CALL_LOG" ]] && fail "no rad/kubectl calls expected when test file is missing"

# --- missing arguments: usage error, exit 1 ---------------------------------
if run_test; then
    fail "expected missing arguments to exit non-zero"
fi

echo "Test direct-module recipe tests passed"
