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
# directory, using fake `rad`/`kubectl` binaries and real jq to assert behavior
# without a live Radius environment: successful deploy, failed deploy (no
# recipe unregister -- this script never registered one), missing test file,
# and missing arguments.

set -euo pipefail

command -v jq >/dev/null || { echo "Error: jq is required for these tests." >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-test-direct-module-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repo"
mkdir -p "$FIXTURE_ROOT/Data/mySqlDatabases/test" "$FIXTURE_ROOT/Data/noTestFile" "$TEST_ROOT/bin"

cat >"$FIXTURE_ROOT/Data/mySqlDatabases/test/app.bicep" <<'EOF'
param applicationName string
param tls string = 'required'
param verifyTransport bool = false
resource mySql 'Radius.Data/mySqlDatabases@2025-08-01-preview' = {
  name: 'testresource'
}
EOF

cp "$REPO_ROOT/Data/mySqlDatabases/test/verify-transport.parameters.json" \
    "$FIXTURE_ROOT/Data/mySqlDatabases/test/verify-transport.parameters.json"

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
        if [[ "$2" == */mySqlDatabases/test/app.bicep ]]; then
            verified=false
            args=("$@")
            for ((i=0; i<${#args[@]}-1; i++)); do
                if [[ "${args[i]}" == --parameters && "${args[i+1]}" == @* ]]; then
                    if ! jq -e '.parameters.verifyTransport.value == true' "${args[i+1]#@}" >/dev/null; then
                        echo "Error: verifyTransport must be a JSON Boolean true." >&2
                        exit 1
                    fi
                    verified=true
                fi
            done
            if [[ "$verified" != true || "$*" == *"verifyTransport="* ]]; then
                echo "Error: Expected a typed verifyTransport parameter file, not a string argument." >&2
                exit 1
            fi
        fi
        if [[ -n "${FAIL_TLS:-}" && "$*" == *"tls=$FAIL_TLS "* ]]; then
            exit 1
        fi
        exit "${DEPLOY_EXIT_CODE:-0}"
        ;;
esac
exit 0
EOF
chmod +x "$TEST_ROOT/bin/rad"

cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >>"$CALL_LOG"
if [[ "$1" == wait ]]; then
    exit "${READINESS_EXIT_CODE:-0}"
fi
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
for tls in required optional; do
    grep -q "^rad deploy .*--parameters tls=$tls --parameters @Data/mySqlDatabases/test/verify-transport.parameters.json" "$CALL_LOG" ||
        fail "expected the $tls transport branch to be tested with its setting assertion enabled"
done
[[ "$(grep -c '^rad app delete' "$CALL_LOG")" -eq 2 ]] ||
    fail "each MySQL transport test must clean up its own application"
[[ "$(grep -c '^kubectl wait deployment .*radapp.io/resource=mysqlclient --for=condition=Available --timeout=180s' "$CALL_LOG")" -eq 2 ]] ||
    fail "both branches must wait for the client probe result before reporting success"
grep -q "rad recipe unregister" "$CALL_LOG" &&
    fail "a direct-module test must never unregister a recipe -- it never registered one"

: >"$CALL_LOG"
if FAIL_TLS=optional run_test Data/mySqlDatabases azure azure; then
    fail "failure in the optional branch must fail the test"
fi
[[ "$(grep -c '^rad app delete' "$CALL_LOG")" -eq 2 ]] ||
    fail "a failed optional branch must still clean up"

: >"$CALL_LOG"
if READINESS_EXIT_CODE=1 run_test Data/mySqlDatabases azure azure; then
    fail "a failed MySQL setting probe must fail even when rad deploy succeeds"
fi
grep -q '^rad app delete' "$CALL_LOG" || fail "readiness failure must still delete the app"

# --- failed deploy: app/K8s cleanup still runs, no recipe unregister, exit 1
: >"$CALL_LOG"
if DEPLOY_EXIT_CODE=1 run_test Data/mySqlDatabases azure azure; then
    fail "expected failed deploy to exit non-zero"
fi
grep -q "kubectl delete secrets" "$CALL_LOG" ||
    fail "expected K8s cleanup to run after a failed deploy"
grep -q "rad recipe unregister" "$CALL_LOG" &&
    fail "a direct-module test must never unregister a recipe on failure either"

# --- a string that looks like a Boolean must not pass the deployment check ---
jq '.parameters.verifyTransport.value = "true"' \
    "$REPO_ROOT/Data/mySqlDatabases/test/verify-transport.parameters.json" \
    >"$FIXTURE_ROOT/Data/mySqlDatabases/test/verify-transport.parameters.json"
: >"$CALL_LOG"
if run_test Data/mySqlDatabases azure azure; then
    fail "a string verifyTransport parameter must fail the test"
fi
grep -q '^rad app delete' "$CALL_LOG" || fail "invalid parameter type must still clean up"

# --- other resource types keep the generic deployment path ------------------
mkdir -p "$FIXTURE_ROOT/Data/widgets/test"
echo "param applicationName string" >"$FIXTURE_ROOT/Data/widgets/test/app.bicep"
: >"$CALL_LOG"
run_test Data/widgets azure azure || fail "expected generic deployment to succeed"
if grep -q 'verify-transport.parameters.json' "$CALL_LOG"; then
    fail "MySQL parameters must not be passed to other resource types"
fi

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
