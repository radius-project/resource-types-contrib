#!/bin/bash
# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-azure-diagnostics-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
export CALL_LOG="$TEST_ROOT/calls"
export RTC_AZURE_DIAGNOSTICS_DIR="$TEST_ROOT/diagnostics"
export AZURE_SUBSCRIPTION_ID=11111111-1111-1111-1111-111111111111
export AZURE_RESOURCE_GROUP=rrttest-123-1-bicep
export RTC_TEST_PLATFORM=azure
export GITHUB_ACTIONS=false
export REAL_TIMEOUT
export REAL_NODE
REAL_NODE="$(command -v node)"
export RAW_TRANSCRIPT_PATH="$TEST_ROOT/raw-transcript-path"
if ! REAL_TIMEOUT="$(command -v timeout)"; then
    echo "Error: GNU timeout is required for Azure diagnostics integration tests." >&2
    exit 1
fi
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/Compute/containers/recipes/azure/bicep" "$TEST_ROOT/Compute/containers/test"
export PATH="$TEST_ROOT/bin:$PATH"

cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
echo "rad $1 $2" >>"$CALL_LOG"
case "$1 $2" in
    "deploy "*)
        if [[ "${DEPLOY_HANG:-0}" == 1 ]]; then exec sleep 30; fi
        if [[ -n "${DEPLOY_ERROR_FILE:-}" ]]; then cat "$DEPLOY_ERROR_FILE"; fi
        exit "${DEPLOY_STATUS:-37}" ;;
    "app delete")
        if [[ "${CLEANUP_HANG:-0}" == 1 ]]; then exec sleep 30; fi
        exit "${CLEANUP_STATUS:-0}" ;;
    "env show") echo '{"id":"/envs/test","properties":{"providers":{"kubernetes":{"namespace":"test-ns"}}}}' ;;
    "resource show")
        if [[ "${ASSERT_FAIL:-0}" == 1 ]]; then echo '{}'
        else echo '{"properties":{"hosts":{"orderProcessor":"a","simple":"b"}}}'; fi ;;
    "resource list")
        echo "${RESOURCE_LIST_JSON:-[]}" ;;
esac
EOF
cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >>"$CALL_LOG"
if [[ "$1" == wait && "${ASSERT_HANG:-0}" == 1 ]]; then exec sleep 30; fi
exit "${CLEANUP_STATUS:-0}"
EOF
cat >"$TEST_ROOT/bin/node" <<'EOF'
#!/bin/bash
[[ "$1" == */collect-azure-test-diagnostics.js ]] || exit 99
if [[ "$2" == --deployment-error ]]; then
    echo deployment-error >>"$CALL_LOG"
    printf '%s\n' "$3" >"$RAW_TRANSCRIPT_PATH"
    if [[ "${CAPTURE_HANG:-0}" == 1 ]]; then exec sleep 30; fi
    if [[ "${CAPTURE_STATUS:-0}" != 0 ]]; then exit "$CAPTURE_STATUS"; fi
    exec "$REAL_NODE" "$@"
fi
echo collector >>"$CALL_LOG"
[[ "$3" == "${AZURE_SUBSCRIPTION_ID:-}" && "$4" == "$AZURE_RESOURCE_GROUP" && "$6" == *T*Z ]] || exit 98
[[ "$8" == "${RTC_TEST_PLATFORM:-kubernetes}" ]] || exit 98
echo '{"mock":"safe-evidence"}' >"$2/azure.json"
exit "${COLLECTOR_STATUS:-0}"
EOF
cat >"$TEST_ROOT/bin/timeout" <<'EOF'
#!/bin/bash
[[ "$1" == --kill-after=5s ]] || exit 97
case "$2 $3 $4" in
    "100s node "*|"30s az resource"|"30s kubectl delete") ;;
    "5s node "*)
        if [[ "${CAPTURE_HANG:-0}" == 1 ]]; then
            shift 2
            exec "$REAL_TIMEOUT" --kill-after=1s 1s "$@"
        fi ;;
    "15m bash -c"|"3m rad app"|"6m rad app"|[0-9]*"s bash -c")
        echo "bounded $2 $3 $4" >>"$CALL_LOG"
        if [[ "${DEPLOY_HANG:-0}" == 1 || "${CLEANUP_HANG:-0}" == 1 ||
              ( "${ASSERT_HANG:-0}" == 1 && "$5" == *rtc_assert_recipe_result* ) ]]; then
            shift 2
            exec "$REAL_TIMEOUT" --kill-after=1s 1s "$@"
        fi ;;
    *) exit 97 ;;
esac
shift 2
exec "$@"
EOF
cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
echo "az $1 $2" >>"$CALL_LOG"
if [[ "$1 $2" == "lock list" ]]; then exit 0; fi
if [[ "$1 $2" == "resource list" ]]; then echo '[]'; exit 0; fi
echo "Unexpected Azure CLI call outside collector" >&2
exit 99
EOF
chmod +x "$TEST_ROOT/bin/"*
printf '%s\n' 'param applicationName string' >"$TEST_ROOT/Compute/containers/test/app.bicep"
touch "$TEST_ROOT/Compute/containers/recipes/azure/bicep/main.bicep"
# shellcheck source=.github/scripts/lib-recipe-test.sh
source "$REPO_ROOT/.github/scripts/lib-recipe-test.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
run_helper() {
    rtc_deploy_and_assert_test_app_once "$TEST_ROOT/Compute/containers/test/app.bicep" \
        "${RESOURCE_TYPE:-Radius.Compute/containers}" testapp /envs/test workspace test-ns
}
assert_failure_cleanup() {
    local status=0
    : >"$CALL_LOG"
    "$@" >"$TEST_ROOT/output" 2>&1 || status=$?
    [[ "$status" == 1 ]] || fail "original normalized failure must remain 1, got $status"
    [[ "$(grep -c '^rad deploy ' "$CALL_LOG")" == 1 ]] || fail "must deploy once"
    [[ "$(grep -c '^rad app delete$' "$CALL_LOG")" == 1 ]] || fail "must delete once"
    [[ "$(grep -c '^kubectl delete ' "$CALL_LOG")" == 3 ]] || fail "must retain all namespace cleanup calls"
}
assert_before_cleanup() {
    awk '
        /^collector$/ { collected++; if (deleted) exit 1 }
        /^rad app delete$/ { deleted++; if (collected != 1) exit 1 }
        END { if (collected != 1 || deleted != 1) exit 1 }
    ' "$CALL_LOG" || fail "collector must run exactly once before cleanup"
}

cat >"$TEST_ROOT/registry-error" <<EOF
Deployment failed:
{"error":{"code":"ResourceDeploymentFailure","target":"/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.ContainerInstance/ngroups/test","details":[{"code":"AzureContainerInstance/RegistryErrorResponse","target":"4114cc1a-89b4-4c63-ac08-97e82f0fa1e8","message":"An error response is received from the docker registry. Please retry later. DO-NOT-SAVE-this-secret"}]}}
TraceId: a9a189ce38e40f636c756f328a897ea0
EOF
DEPLOY_ERROR_FILE="$TEST_ROOT/registry-error" assert_failure_cleanup run_helper
assert_before_cleanup
awk '
    /^deployment-error$/ { captured++; if (collected) exit 1 }
    /^collector$/ { collected++; if (captured != 1) exit 1 }
    END { if (captured != 1 || collected != 1) exit 1 }
' "$CALL_LOG" || fail "deployment error capture must precede snapshots and cleanup"
[[ ! -e "$(cat "$RAW_TRANSCRIPT_PATH")" ]] || fail "raw deployment transcript must be removed"
reports=("$RTC_AZURE_DIAGNOSTICS_DIR"/deployment-error-*/deployment-error.json)
[[ "${#reports[@]}" == 1 && -f "${reports[0]}" ]] || fail "must save one filtered deployment report"
jq -e '
    .app | startswith("testapp-")
' "${reports[0]}" >/dev/null || fail "report must identify the test application"
jq -e '
    .errors[0].code == "AzureContainerInstance/RegistryErrorResponse" and
    .errors[0].errorTargets == ["4114cc1a-89b4-4c63-ac08-97e82f0fa1e8"] and
    .traceIds == ["a9a189ce38e40f636c756f328a897ea0"]
' "${reports[0]}" >/dev/null || fail "must retain provider code, targets, and CLI trace ID"
if grep -Rq 'DO-NOT-SAVE-this-secret' "$RTC_AZURE_DIAGNOSTICS_DIR"; then fail "must not save raw errors"; fi
for status in 9 124; do
    CAPTURE_STATUS="$status" assert_failure_cleanup run_helper
    assert_before_cleanup
    grep -q 'Deployment error capture incomplete' "$TEST_ROOT/output" || fail "capture failure must be explicit"
done
CAPTURE_HANG=1 assert_failure_cleanup run_helper
assert_before_cleanup
grep -q 'Deployment error capture incomplete' "$TEST_ROOT/output" || fail "stalled capture must be explicit"
for capture_status in 0 124; do
    : >"$CALL_LOG"
    status=0
    RTC_TEST_DIAGNOSTICS_DIR="$TEST_ROOT/direct-helper" RTC_TEST_DIAGNOSTIC_APP=testapp \
        RTC_TEST_DIAGNOSTIC_STARTED=2026-11-07T09:30:00Z CAPTURE_STATUS="$capture_status" \
        DEPLOY_ERROR_FILE="$TEST_ROOT/registry-error" \
        rtc_deploy_with_retry test.bicep >"$TEST_ROOT/output" 2>&1 || status=$?
    [[ "$status" == 37 ]] || fail "capture must preserve the raw deployment exit code"
    [[ "$(grep -c '^rad deploy ' "$CALL_LOG")" == 1 ]] || fail "registry errors must not retry"
done

for status in 0 9 124 137; do
    COLLECTOR_STATUS="$status" assert_failure_cleanup run_helper
    assert_before_cleanup
done
CLEANUP_STATUS=8 assert_failure_cleanup run_helper
assert_before_cleanup
DEPLOY_STATUS=0 ASSERT_FAIL=1 assert_failure_cleanup run_helper
assert_before_cleanup
for status in 124 137; do
    GITHUB_ACTIONS=true DEPLOY_STATUS="$status" assert_failure_cleanup run_helper
    assert_before_cleanup
    grep -q '^bounded 15m bash -c$' "$CALL_LOG" || fail "CI deployment retries must be bounded"
    grep -q '^bounded 3m rad app$' "$CALL_LOG" || fail "CI cleanup must be bounded"
    grep -q 'exceeded its 15-minute limit' "$TEST_ROOT/output" || fail "deployment timeout must be explicit"
done
GITHUB_ACTIONS=true DEPLOY_HANG=1 assert_failure_cleanup run_helper
assert_before_cleanup
grep -q 'exceeded its 15-minute limit' "$TEST_ROOT/output" || fail "a stalled process must reach diagnostics"
GITHUB_ACTIONS=true CLEANUP_HANG=1 assert_failure_cleanup run_helper
assert_before_cleanup
GITHUB_ACTIONS=true CLEANUP_STATUS=124 assert_failure_cleanup run_helper
assert_before_cleanup
grep -q 'Test app cleanup failed' "$TEST_ROOT/output" || fail "cleanup timeout must be explicit"
GITHUB_ACTIONS=true DEPLOY_STATUS=0 ASSERT_FAIL=1 assert_failure_cleanup run_helper
assert_before_cleanup
grep -q '^bounded 3m rad app$' "$CALL_LOG" || fail "assertion failure cleanup must be bounded"

for platform in kubernetes aws ""; do
    GITHUB_ACTIONS=true RTC_TEST_PLATFORM="$platform" assert_failure_cleanup run_helper
    assert_before_cleanup
    if grep -q '^bounded' "$CALL_LOG"; then fail "non-Azure tests must not acquire new time limits"; fi
    if grep -q '^deployment-error$' "$CALL_LOG"; then fail "non-Azure tests must not capture ACI errors"; fi
done
RESOURCE_TYPE=Radius.Data/widgets assert_failure_cleanup run_helper
assert_before_cleanup
for resource_type in Radius.AI/models Radius.Data/mongoDatabases; do
    RESOURCE_TYPE="$resource_type" assert_failure_cleanup run_helper
    assert_before_cleanup
    GITHUB_ACTIONS=true RESOURCE_TYPE="$resource_type" DEPLOY_HANG=1 \
        RTC_AZURE_TEST_STEP_DEADLINE_EPOCH="$(( $(date +%s) + 600 ))" assert_failure_cleanup run_helper
    assert_before_cleanup
    grep -q 'collecting diagnostics before the step deadline' "$TEST_ROOT/output" ||
        fail "non-container stalls must reach diagnostics before workflow timeout"
    grep -q '^bounded 3m rad app$' "$CALL_LOG" || fail "failure cleanup must be bounded"
done
(
    : >"$CALL_LOG"
    status=0
    GITHUB_ACTIONS=true RESOURCE_TYPE=Radius.AI/models \
        RTC_AZURE_LOCK_GUARD=1 \
        RTC_AZURE_TEST_STEP_DEADLINE_EPOCH="$(( $(date +%s) + 300 ))" \
        run_helper >"$TEST_ROOT/output" 2>&1 || status=$?
    [[ "$status" == 1 ]] || fail "exhausted step budget must fail"
    if grep -q '^rad deploy ' "$CALL_LOG"; then fail "must not allocate after the step budget expires"; fi
    grep -q 'step budget exhausted' "$TEST_ROOT/output" || fail "budget failure must be explicit"
    [[ "$(grep -c '^collector$' "$CALL_LOG")" == 1 ]] || fail "exhausted budget must collect immediately"
    if grep -q '^az ' "$CALL_LOG"; then fail "exhausted budget must precede lock snapshots"; fi
)
(
    : >"$CALL_LOG"
    status=0
    GITHUB_ACTIONS=true RESOURCE_TYPE=Radius.Data/postgreSqlDatabases RTC_POSTGRES_CAPACITY_RECOVERY=1 \
        RTC_AZURE_TEST_STEP_DEADLINE_EPOCH="$(( $(date +%s) + 900 ))" \
        run_helper >"$TEST_ROOT/output" 2>&1 || status=$?
    [[ "$status" == 1 ]] || fail "exhausted PostgreSQL cleanup reserve must fail"
    [[ "$(grep -c '^collector$' "$CALL_LOG")" == 1 ]] || fail "PostgreSQL budget failure must collect"
    if grep -qE '^(rad|az) ' "$CALL_LOG"; then fail "PostgreSQL budget must precede snapshots and allocation"; fi
)
(
    # shellcheck disable=SC2329 # Called by the sourced helper.
    command() {
        if [[ "$*" == "-v timeout" ]]; then return 1; fi
        builtin command "$@"
    }
    : >"$CALL_LOG"
    status=0
    GITHUB_ACTIONS=true RESOURCE_TYPE=Radius.AI/models \
        RTC_AZURE_TEST_STEP_DEADLINE_EPOCH="$(( $(date +%s) + 600 ))" \
        run_helper >"$TEST_ROOT/output" 2>&1 || status=$?
    [[ "$status" == 1 ]] || fail "non-container deadlines must require GNU timeout"
    grep -q 'Azure test deadlines require GNU timeout' "$TEST_ROOT/output" || fail "missing timeout must be explicit"
    if grep -q '^rad ' "$CALL_LOG"; then fail "missing timeout must prevent allocation"; fi
)
(
    deadline=$(( $(date +%s) + 600 ))
    # shellcheck disable=SC2329 # Called by the sourced helper.
    date() {
        if [[ "$*" == +%s ]] && grep -q '^rad deploy ' "$CALL_LOG"; then
            printf '%s\n' "$clock_after_deploy"
        else
            command date "$@"
        fi
    }
    for remaining in 0 1 60; do
        clock_after_deploy=$((deadline - 360 - remaining))
        GITHUB_ACTIONS=true RESOURCE_TYPE=Radius.Data/mySqlDatabases DEPLOY_STATUS=0 ASSERT_HANG=1 \
            RTC_AZURE_TEST_STEP_DEADLINE_EPOCH="$deadline" assert_failure_cleanup run_helper
        assert_before_cleanup
        grep -q '^bounded 3m rad app$' "$CALL_LOG" || fail "assertion timeout must retain bounded cleanup"
        if ((remaining == 0)); then
            if grep -q '^kubectl wait ' "$CALL_LOG"; then fail "expired assertion budget must not start assertions"; fi
            grep -q 'budget exhausted before assertions' "$TEST_ROOT/output" || fail "expired assertion budget must be explicit"
        else
            grep -q "^bounded ${remaining}s bash -c$" "$CALL_LOG" || fail "assertions must use the recalculated budget"
            grep -q 'assertions exceeded the step budget' "$TEST_ROOT/output" || fail "stalled assertions must reach diagnostics"
        fi
    done
    : >"$CALL_LOG"
    GITHUB_ACTIONS=true RESOURCE_TYPE=Radius.Data/mySqlDatabases DEPLOY_STATUS=0 \
        RTC_AZURE_TEST_STEP_DEADLINE_EPOCH="$deadline" run_helper >"$TEST_ROOT/output" 2>&1 ||
        fail "bounded successful assertions must remain successful"
    grep -q '^kubectl wait ' "$CALL_LOG" || fail "bounded assertions must run"
    if grep -qE '^(collector|deployment-error)$' "$CALL_LOG"; then fail "successful assertions must not collect"; fi
)
: >"$CALL_LOG"
DEPLOY_STATUS=0 run_helper >"$TEST_ROOT/output" 2>&1 || fail "successful test must remain successful"
if grep -qE '^(collector|deployment-error)$' "$CALL_LOG"; then fail "success must not collect"; fi
if grep -q '^bounded' "$CALL_LOG"; then fail "local runs must retain their existing time limits"; fi
: >"$CALL_LOG"
GITHUB_ACTIONS=true DEPLOY_STATUS=0 run_helper >"$TEST_ROOT/output" 2>&1 || fail "CI success must remain successful"
if grep -q '^deployment-error$' "$CALL_LOG"; then fail "CI success must not capture errors"; fi
if grep -q '^bounded 3m rad app$' "$CALL_LOG"; then
    fail "successful CI cleanup must not have a timeout"
fi
grep -q '^bounded 15m bash -c$' "$CALL_LOG" || fail "CI deployment retries must remain bounded"

# Missing dependencies must produce a status artifact but cannot stop cleanup.
(
    # shellcheck disable=SC2329 # Called by the sourced helper.
    command() {
        if [[ "$*" == "-v node" ]]; then return 1; fi
        builtin command "$@"
    }
    assert_failure_cleanup run_helper
    grep -q 'Failure diagnostics require node' "$TEST_ROOT/output" || fail "missing tool must be explicit"
)
# A bad output path must not prevent app cleanup.
touch "$TEST_ROOT/not-a-directory"
RTC_AZURE_DIAGNOSTICS_DIR="$TEST_ROOT/not-a-directory" assert_failure_cleanup run_helper
grep -q 'Could not create failure diagnostic directory' "$TEST_ROOT/output" || fail "output failure must be explicit"

run_recipe() {
    (cd "$TEST_ROOT"; bash "$REPO_ROOT/.github/scripts/test-recipe.sh" Compute/containers/recipes/azure/bicep)
}
run_pack_entry() {
    (cd "$TEST_ROOT"; bash "$REPO_ROOT/.github/scripts/test-recipe-pack-entry.sh" Compute/containers workspace environment)
}
# Recipe path, not an inherited platform setting, selects Azure diagnostics.
RTC_TEST_PLATFORM=kubernetes assert_failure_cleanup run_recipe
assert_before_cleanup
assert_failure_cleanup run_pack_entry
assert_before_cleanup
DEPLOY_STATUS=0 ASSERT_FAIL=1 assert_failure_cleanup run_pack_entry
assert_before_cleanup
# Lock guard failures must retain diagnostics and use bounded Kubernetes cleanup.
for deploy_status in 0 37; do
    : >"$CALL_LOG"
    if DEPLOY_STATUS="$deploy_status" ASSERT_FAIL=1 \
        RESOURCE_LIST_JSON='[{"outputResources":[{"id":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Authorization/locks/test"}]}]' \
        run_pack_entry >"$TEST_ROOT/output" 2>&1; then
        fail "a test-owned lock missing from Azure must fail the entry"
    fi
    grep -q 'Skipping Radius application deletion' "$TEST_ROOT/output" ||
        fail "the lock guard must block application deletion"
    if grep -q '^rad app delete$' "$CALL_LOG"; then
        fail "a lock guard failure must skip application deletion"
    fi
    [[ "$(grep -c '^kubectl delete .*--request-timeout=10s --wait=false$' "$CALL_LOG")" == 3 ]] ||
        fail "lock guard failures must retain bounded Kubernetes cleanup"
    awk '
        /^collector$/ { collected++; if (cleaned) exit 1 }
        /^kubectl delete / { cleaned++; if (collected != 1) exit 1 }
        END { if (collected != 1 || cleaned != 3) exit 1 }
    ' "$CALL_LOG" || fail "diagnostics must run once before lock guard cleanup"
done
# An output directory is required in both CI and local runs.
for github_actions in true false; do
    (
        cd "$TEST_ROOT"
        unset RTC_AZURE_DIAGNOSTICS_DIR
        export GITHUB_ACTIONS="$github_actions"
        assert_failure_cleanup run_recipe
        if grep -qE '^(collector|deployment-error)$' "$CALL_LOG"; then fail "unset directory must disable collection"; fi
        [[ ! -e radius-pod-logs ]] || fail "unset directory must not create a default output path"
    )
    GITHUB_ACTIONS="$github_actions" RTC_AZURE_DIAGNOSTICS_DIR="" assert_failure_cleanup run_recipe
    if grep -qE '^(collector|deployment-error)$' "$CALL_LOG"; then fail "explicit empty directory must disable collection"; fi
done
RTC_TEST_DIAGNOSTICS_DIR="" assert_failure_cleanup run_helper
if grep -qE '^(collector|deployment-error)$' "$CALL_LOG"; then fail "empty new directory setting must disable fallback"; fi
DEPLOY_STATUS=0 CLEANUP_STATUS=8 assert_failure_cleanup run_helper
[[ "$(grep -c '^collector$' "$CALL_LOG")" == 1 ]] || fail "cleanup-only failures must collect once"
: >"$CALL_LOG"
RTC_TEST_PLATFORM=kubernetes RTC_TEST_DIAGNOSTICS_DIR="$TEST_ROOT/workflow-diagnostics" \
    rtc_collect_test_diagnostics workflow workflow-failure "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >"$TEST_ROOT/output" 2>&1 || fail "workflow failures must collect without a test app"
[[ "$(grep -c '^collector$' "$CALL_LOG")" == 1 ]] || fail "workflow fallback must collect"
if grep -q '^rad ' "$CALL_LOG"; then fail "workflow fallback must not deploy or delete an app"; fi
grep -Rq 'collector exit 124' "$RTC_AZURE_DIAGNOSTICS_DIR" || fail "timeout status must persist"
grep -Rq 'safe-evidence' "$RTC_AZURE_DIAGNOSTICS_DIR" || fail "evidence must persist after cleanup"
echo "Azure diagnostics integration tests passed"
