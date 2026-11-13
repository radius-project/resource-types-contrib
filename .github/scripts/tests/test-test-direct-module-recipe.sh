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
            if [[ "${EXPECT_VERIFY_TRANSPORT:-true}" == "true" ]]; then
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
            elif [[ "$*" == *"tls="* || "$*" == *"verify-transport.parameters.json"* ]]; then
                echo "Error: connection-only mode must not assert transport policy." >&2
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
        cd "$FIXTURE_ROOT"
        PATH="$TEST_ROOT/bin:$PATH" "$REPO_ROOT/.github/scripts/test-direct-module-recipe.sh" "$@"
    )
}

run_entry_test() {
    (
        export EXPECT_VERIFY_TRANSPORT="${EXPECT_VERIFY_TRANSPORT:-true}"
        cd "$FIXTURE_ROOT"
        PATH="$TEST_ROOT/bin:$PATH" "$REPO_ROOT/.github/scripts/test-recipe-pack-entry.sh" "$@"
    )
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

mkdir -p "$FIXTURE_ROOT/Data/sqlServerDatabases/test"
echo "param applicationName string" >"$FIXTURE_ROOT/Data/sqlServerDatabases/test/app.bicep"
for consent in "" N invalid; do
    : >"$CALL_LOG"
    status=0
    RTC_TEST_PLATFORM=kubernetes RTC_SQLSERVER_ACCEPT_EULA="$consent" \
        run_entry_test Data/sqlServerDatabases fixture-ws fixture-env || status=$?
    if [[ "$consent" == invalid ]]; then
        [[ "$status" != 0 ]] || fail "invalid SQL consent must fail"
    else
        [[ "$status" == 0 ]] || fail "SQL entry must skip without operator consent"
    fi
    [[ ! -s "$CALL_LOG" ]] || fail "SQL consent gate must run before cluster access"
done
: >"$CALL_LOG"
RTC_TEST_PLATFORM=kubernetes RTC_SQLSERVER_ACCEPT_EULA=Y \
    run_entry_test Data/sqlServerDatabases fixture-ws fixture-env ||
    fail "explicit SQL opt-in must reach the configured Environment"
grep -q '^rad deploy Data/sqlServerDatabases/test/app.bicep ' "$CALL_LOG" ||
    fail "explicit opt-in must retain the SQL test"
if grep -q 'sqlServerAcceptEula' "$CALL_LOG"; then
    fail "the entry runner must not change Environment license settings"
fi

for type_dir in Data/mongoDatabases Storage/objectStorage; do
    mkdir -p "$FIXTURE_ROOT/$type_dir/test"
    cat >"$FIXTURE_ROOT/$type_dir/test/test-kubernetes.sh" <<'EOF'
#!/bin/bash
echo "credential-helper $*" >>"$CALL_LOG"
exit "${HELPER_EXIT_CODE:-0}"
EOF
    : >"$CALL_LOG"
    RTC_TEST_PLATFORM=kubernetes run_entry_test "$type_dir" fixture-ws fixture-env verify-kubernetes-credentials ||
        fail "expected $type_dir to use its credential helper"
    [[ "$(cat "$CALL_LOG")" == "credential-helper fixture-ws fixture-env" ]] ||
        fail "credential helper must run before generic cluster access, without extra arguments"
    if RTC_TEST_PLATFORM=kubernetes HELPER_EXIT_CODE=7 \
        run_entry_test "$type_dir" fixture-ws fixture-env verify-kubernetes-credentials; then
        fail "credential helper failure must fail the entry test"
    fi
    : >"$CALL_LOG"
    if RTC_TEST_PLATFORM=azure run_entry_test "$type_dir" fixture-ws fixture-env verify-kubernetes-credentials; then
        fail "credential helper mode must reject non-Kubernetes use"
    fi
    [[ ! -s "$CALL_LOG" ]] || fail "rejected credential mode must not access the cluster"
    rm "$FIXTURE_ROOT/$type_dir/test/test-kubernetes.sh"
    if RTC_TEST_PLATFORM=kubernetes run_entry_test "$type_dir" fixture-ws fixture-env verify-kubernetes-credentials; then
        fail "missing credential helper must fail, not skip"
    fi
done

# --- successful deploy: resolves environment, deploys, asserts, cleans up ---
: >"$CALL_LOG"
DEPLOY_EXIT_CODE=0 run_test Data/mySqlDatabases azure azure verify-transport ||
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

# --- connection-only MySQL mode deploys once without policy parameters -----
: >"$CALL_LOG"
EXPECT_VERIFY_TRANSPORT=false run_entry_test Data/mySqlDatabases azure azure connection-only ||
    fail "expected the MySQL connection-only probe to succeed"
[[ "$(grep -c '^rad deploy' "$CALL_LOG")" -eq 1 ]] ||
    fail "connection-only mode must deploy one MySQL test application"
if grep -Eq 'tls=|verify-transport.parameters.json' "$CALL_LOG"; then
    fail "connection-only mode must not pass transport-policy parameters"
fi
[[ "$(grep -c '^rad app delete' "$CALL_LOG")" -eq 1 ]] ||
    fail "connection-only mode must clean up its application"

: >"$CALL_LOG"
if run_entry_test Data/mySqlDatabases azure azure unsupported-mode; then
    fail "an unsupported MySQL test mode must fail"
fi
if grep -q '^rad deploy' "$CALL_LOG"; then
    fail "an unsupported MySQL test mode must fail before deployment"
fi

: >"$CALL_LOG"
if FAIL_TLS=optional run_test Data/mySqlDatabases azure azure verify-transport; then
    fail "failure in the optional branch must fail the test"
fi
[[ "$(grep -c '^rad app delete' "$CALL_LOG")" -eq 2 ]] ||
    fail "a failed optional branch must still clean up"

: >"$CALL_LOG"
if READINESS_EXIT_CODE=1 run_test Data/mySqlDatabases azure azure verify-transport; then
    fail "a failed MySQL setting probe must fail even when rad deploy succeeds"
fi
grep -q '^rad app delete' "$CALL_LOG" || fail "readiness failure must still delete the app"

# --- failed deploy: app/K8s cleanup still runs, no recipe unregister, exit 1
: >"$CALL_LOG"
if DEPLOY_EXIT_CODE=1 run_test Data/mySqlDatabases azure azure verify-transport; then
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
if run_test Data/mySqlDatabases azure azure verify-transport; then
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

# --- Azure Redis checks both credential paths and waits for readiness -----
mkdir -p "$FIXTURE_ROOT/Data/redisCaches/test"
echo "param applicationName string" >"$FIXTURE_ROOT/Data/redisCaches/test/app.bicep"
: >"$CALL_LOG"
RTC_TEST_PLATFORM=azure run_entry_test Data/redisCaches azure azure ||
    fail "expected Azure Redis deployment to succeed"
grep -q '^rad deploy .*--parameters cachePlatform=azure' "$CALL_LOG" ||
    fail "Azure Redis must enable the credential probe"
grep -q '^kubectl wait deployment .*radapp.io/resource=democontainer --for=condition=Available --timeout=180s' "$CALL_LOG" ||
    fail "Redis must wait for the client probe"

: >"$CALL_LOG"
if RTC_TEST_PLATFORM=azure READINESS_EXIT_CODE=1 run_entry_test Data/redisCaches azure azure; then
    fail "a failed Redis probe must fail the test"
fi
grep -q '^rad app delete' "$CALL_LOG" || fail "Redis probe failure must still clean up"

: >"$CALL_LOG"
RTC_TEST_PLATFORM=kubernetes run_entry_test Data/redisCaches default default ||
    fail "expected Kubernetes Redis deployment to succeed"
if grep -q 'cachePlatform=azure' "$CALL_LOG"; then
    fail "Kubernetes Redis must not require Azure credentials"
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
