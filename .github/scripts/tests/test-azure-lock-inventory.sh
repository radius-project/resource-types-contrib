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

command -v jq >/dev/null || { echo "Error: jq is required for these tests." >&2; exit 1; }
REAL_TIMEOUT="$(command -v timeout)"
export REAL_TIMEOUT
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-azure-lock-inventory-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export CALL_LOG="$TEST_ROOT/calls"
export RTC_AZURE_LOCK_GUARD=1 AZURE_RESOURCE_GROUP=rg AZURE_SUBSCRIPTION_ID=sub
export GITHUB_ACTIONS=false RTC_POSTGRES_CAPACITY_RECOVERY=0
export RTC_AZURE_DIAGNOSTICS_DIR="" RTC_TEST_DIAGNOSTICS_DIR="$TEST_ROOT/diagnostics"
unset RTC_AZURE_TEST_STEP_DEADLINE_EPOCH RTC_LIB_RECIPE_TEST_SOURCED
export EXISTING_LOCK="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Authorization/locks/existing"
export OWNED_LOCK="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Cache/redis/test/providers/Microsoft.Authorization/locks/new"
export UNRELATED_LOCK="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Cache/redis/other/providers/Microsoft.Authorization/locks/new"
INVENTORY_JSON="$(jq -n --arg existing "$EXISTING_LOCK" --arg owned "$OWNED_LOCK" '
    [{properties: {status: {outputResources: [
        {id: ("/planes/azure/azurecloud" + $existing)},
        {id: ("/planes/azure/azurecloud" + $owned)}
    ]}}}]
')"
export INVENTORY_JSON
mkdir -p "$TEST_ROOT/bin"

cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
echo "rad $*" >>"$CALL_LOG"
case "$1 $2" in
    "deploy "*) exit "${DEPLOY_STATUS:-0}" ;;
    "resource list")
        case "$INVENTORY_MODE" in
            failed)
                # Even useful-looking output from a failed request is untrusted.
                printf '%s\n' "$INVENTORY_JSON"
                exit 9 ;;
            malformed) printf '%s\n' "$INVENTORY_JSON" '{"incomplete":' ;;
            empty) echo '[]' ;;
            normal) printf '%s\n' "$INVENTORY_JSON" ;;
            *) exit 99 ;;
        esac ;;
    "app delete")
        if [[ "${DELETE_HANG:-0}" == 1 ]]; then exec sleep 30; fi
        exit "${DELETE_STATUS:-0}" ;;
    *) echo "Unexpected rad call: $*" >&2; exit 99 ;;
esac
EOF
cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
echo "az $*" >>"$CALL_LOG"
case "$1 $2" in
    "lock list")
        printf '%s\n' "$EXISTING_LOCK"
        if grep -q '^rad deploy ' "$CALL_LOG"; then
            printf '%s\n' "$OWNED_LOCK" "$UNRELATED_LOCK"
        fi ;;
    "lock delete") exit 0 ;;
    *) echo "Unexpected az call: $*" >&2; exit 99 ;;
esac
EOF
cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >>"$CALL_LOG"
exit "${KUBECTL_STATUS:-0}"
EOF
cat >"$TEST_ROOT/bin/node" <<'EOF'
#!/bin/bash
[[ "$1" == */collect-azure-test-diagnostics.js ]] || exit 99
echo "diagnostics $6" >>"$CALL_LOG"
echo '{"fixture":true}' >"$2/azure.json"
exit "${DIAGNOSTICS_STATUS:-0}"
EOF
cat >"$TEST_ROOT/bin/timeout" <<'EOF'
#!/bin/bash
echo "timeout $*" >>"$CALL_LOG"
case "$1 $2 $3 $4" in
    "--kill-after=5s 3m rad app"|"--kill-after=5s 100s node "*) ;;
    *) exit 99 ;;
esac
shift 2
# Check the production limits above, then shorten only the fixture's wait.
exec "$REAL_TIMEOUT" --kill-after=1s 1s "$@"
EOF
chmod +x "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH"
printf '%s\n' 'param applicationName string' >"$TEST_ROOT/app.bicep"
# shellcheck source=.github/scripts/lib-recipe-test.sh
source "$REPO_ROOT/.github/scripts/lib-recipe-test.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
run_case() {
    : >"$CALL_LOG"
    local status=0
    rtc_deploy_and_assert_test_app "$TEST_ROOT/app.bicep" Radius.Data/redisCaches \
        inventory-test /envs/test workspace test-ns >"$TEST_ROOT/output" 2>&1 || status=$?
    [[ "$status" == "$1" ]] || {
        cat "$TEST_ROOT/output" >&2
        fail "$INVENTORY_MODE: expected status $1, got $status"
    }
}
assert_cleanup() {
    local app_name kind
    app_name="$(sed -nE 's/^rad deploy .*--application ([^ ]+).*/\1/p' "$CALL_LOG")"
    [[ "$app_name" == inventory-test-* ]] || fail "missing deployed application name"
    [[ "$(grep -c '^rad app delete ' "$CALL_LOG")" == 1 ]] || fail "delete app exactly once"
    grep -Fxq "rad app delete $app_name --workspace workspace --yes" "$CALL_LOG" ||
        fail "cleanup must target the deployed app and workspace"
    [[ "$(grep -c '^kubectl ' "$CALL_LOG")" == 3 ]] || fail "clean up all three Kubernetes kinds"
    for kind in secrets deployments services; do
        grep -Fxq "kubectl delete $kind -l radapp.io/application=$app_name -n test-ns" "$CALL_LOG" ||
            fail "Kubernetes cleanup must select only the test app in its namespace"
    done
}
assert_no_lock_deletes() {
    if grep -q '^az lock delete ' "$CALL_LOG"; then
        fail "must not delete locks without verified ownership"
    fi
}
assert_diagnostics() {
    local diagnostics_line cleanup_line
    [[ "$(grep -c '^diagnostics ' "$CALL_LOG")" == 1 ]] || fail "collect diagnostics exactly once"
    diagnostics_line="$(grep -n '^diagnostics ' "$CALL_LOG" | cut -d: -f1)"
    cleanup_line="$(grep -nE '^rad app delete |^kubectl delete ' "$CALL_LOG" | head -n1 | cut -d: -f1)"
    ((diagnostics_line < cleanup_line)) || fail "collect diagnostics before app or Kubernetes cleanup"
}
assert_fallback() {
    assert_cleanup
    assert_no_lock_deletes
    assert_diagnostics
    [[ "$(grep -c '^timeout --kill-after=5s 3m rad app delete ' "$CALL_LOG")" == 1 ]] ||
        fail "bound fallback deletion exactly once"
    grep -q '^timeout --kill-after=5s 3m rad app delete ' "$CALL_LOG" ||
        fail "fallback deletion needs a three-minute timeout and a five-second kill limit"
    grep -Fq 'Continuing with bounded Radius application deletion without lock ownership data.' "$TEST_ROOT/output" ||
        fail "report missing ownership data"
}

# Include partial valid JSON before the parse error to prove it is discarded.
for mode in failed malformed; do
    INVENTORY_MODE="$mode" run_case 1
    assert_fallback
    DEPLOY_STATUS=17 INVENTORY_MODE="$mode" run_case 1
    assert_fallback
done

# Failed diagnostics must not hide the inventory failure or prevent cleanup.
for mode in failed malformed; do
    DIAGNOSTICS_STATUS=6 INVENTORY_MODE="$mode" run_case 1
    assert_fallback
    grep -Fq 'Error: Diagnostic collection failed after lock inventory failure; continuing cleanup.' "$TEST_ROOT/output" ||
        fail "report diagnostic collection failure"
    DIAGNOSTICS_STATUS=6 DELETE_STATUS=7 KUBECTL_STATUS=8 INVENTORY_MODE="$mode" run_case 1
    assert_fallback
    DEPLOY_STATUS=17 DIAGNOSTICS_STATUS=6 INVENTORY_MODE="$mode" run_case 1
    assert_fallback
done

# Failed cleanup and an actual timeout must still reach safe Kubernetes cleanup.
DELETE_STATUS=7 INVENTORY_MODE=failed run_case 1
assert_fallback
KUBECTL_STATUS=8 INVENTORY_MODE=malformed run_case 1
assert_fallback
started="$SECONDS"
DELETE_HANG=1 INVENTORY_MODE=failed run_case 1
assert_fallback
((SECONDS - started < 10)) || fail "fallback deletion did not stop the hanging app delete"
grep -Fq 'Error: Test app cleanup failed.' "$TEST_ROOT/output" ||
    fail "report timed-out application cleanup"

# A valid empty inventory does not prove that any newly observed lock is owned.
INVENTORY_MODE=empty run_case 0
assert_cleanup
assert_no_lock_deletes
if grep -q '^timeout ' "$CALL_LOG"; then fail "do not shorten healthy cleanup"; fi

# Normal inventory deletes only the new owned lock, before deleting the app.
INVENTORY_MODE=normal run_case 0
assert_cleanup
[[ "$(grep -c '^az lock delete ' "$CALL_LOG")" == 1 ]] || fail "delete only the new owned lock"
grep -Fxq "az lock delete --ids $OWNED_LOCK --subscription sub" "$CALL_LOG" ||
    fail "delete the verified new lock"
lock_line="$(grep -n '^az lock delete ' "$CALL_LOG" | cut -d: -f1)"
app_line="$(grep -n '^rad app delete ' "$CALL_LOG" | cut -d: -f1)"
((lock_line < app_line)) || fail "remove owned lock before application deletion"
if grep -q '^timeout ' "$CALL_LOG"; then fail "do not shorten healthy cleanup"; fi

DEPLOY_STATUS=17 INVENTORY_MODE=normal run_case 1
assert_cleanup
assert_diagnostics
echo "PASS: Azure lock inventory failures, bounded fallback, and ownership checks"
