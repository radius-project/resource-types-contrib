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

# Unit tests for lib-recipe-test.sh. Uses fake rad/kubectl stand-ins on
# PATH (no live cluster) to exercise environment resolution and the
# deploy/assert/cleanup flow shared by test-recipe.sh and
# test-direct-module-recipe.sh.

set -euo pipefail

command -v jq >/dev/null || { echo "Error: jq is required for these tests." >&2; exit 1; }
REAL_SLEEP="$(command -v sleep)"
export REAL_SLEEP

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-recipe-test-lib-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN"
CALL_LOG="$TEST_ROOT/calls.log"

cat >"$MOCK_BIN/rad" <<'EOF'
#!/bin/bash
echo "rad $*" >>"$CALL_LOG"
case "$1 $2" in
    "workspace switch")
        exit "${WORKSPACE_EXIT_CODE:-0}"
        ;;
    "env show")
        if [[ "${ENV_SHOW_FAIL:-}" == "1" ]]; then
            exit 1
        fi
        if [[ -n "${ENV_JSON:-}" ]]; then
            echo "$ENV_JSON"
        else
            echo "{\"id\":\"/planes/radius/local/resourceGroups/default/providers/Applications.Core/environments/${3:-default}\",\"properties\":{\"providers\":{\"kubernetes\":{\"namespace\":\"${ENV_NAMESPACE:-default-ns}\"}}}}"
        fi
        ;;
    "deploy "*)
        deploy_attempt=$(grep -c '^rad deploy ' "$CALL_LOG")
        deploy_exit_code="${DEPLOY_EXIT_CODE:-0}"
        if (( deploy_attempt <= ${DEPLOY_FAILURES:-0} )); then
            deploy_exit_code=1
        fi
        if [[ "$deploy_exit_code" -ne 0 ]]; then
            if [[ "$deploy_attempt" -gt 1 && -n "${DEPLOY_ERROR_AFTER_FIRST:-}" ]]; then
                printf '%s\n' "$DEPLOY_ERROR_AFTER_FIRST" >&2
            else
                printf '%s\n' "${DEPLOY_ERROR:-}" >&2
            fi
        fi
        exit "$deploy_exit_code"
        ;;
    "resource show")
        # Used by the containers/postgresql assertion helpers.
        case "$3" in
            "Radius.Compute/containers")
                if [[ -n "${CONTAINERS_JSON:-}" ]]; then
                    echo "$CONTAINERS_JSON"
                    exit 0
                fi
                if [[ "$4" == "myApp" ]]; then
                    echo '{"properties":{"hosts":{"orderProcessor":"host-a"}}}'
                else
                    echo "{\"properties\":{\"hosts\":{\"simple\":\"${PEER_HOST:-host-b}\"}}}"
                fi
                ;;
            "Radius.Data/postgreSqlDatabases")
                if [[ -n "${POSTGRES_JSON:-}" ]]; then
                    echo "$POSTGRES_JSON"
                else
                    echo '{"properties":{"host":"pg-host","port":5432,"database":"appdb"}}'
                fi
                ;;
        esac
        ;;
    "resource list")
        printf '%s\n' "${RESOURCE_LIST_JSON:-[]}"
        ;;
    "app delete")
        if [[ -n "${APP_DELETE_DELAY_SECONDS:-}" ]]; then
            sleep "$APP_DELETE_DELAY_SECONDS"
        fi
        [[ -n "${APP_DELETE_OUTPUT:-}" ]] && echo "$APP_DELETE_OUTPUT" >&2
        exit "${APP_DELETE_EXIT_CODE:-0}"
        ;;
esac
EOF
chmod +x "$MOCK_BIN/rad"

cat >"$MOCK_BIN/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >>"$CALL_LOG"
exit "${KUBECTL_EXIT_CODE:-0}"
EOF
chmod +x "$MOCK_BIN/kubectl"

cat >"$MOCK_BIN/az" <<'EOF'
#!/bin/bash
echo "az $*" >>"$CALL_LOG"
case "$1 $2" in
    "resource list")
        if [[ "${AZ_RESOURCE_LIST_FAIL:-0}" == 1 ]]; then exit 1; fi
        if grep -q '^rad app delete' "$CALL_LOG"; then
            printf '%s\n' "${AZ_RESOURCES_AFTER:-[]}"
        else
            echo '[]'
        fi
        ;;
    "lock list")
        lock_list_calls=0
        if [[ -f "$AZ_LOCK_STATE_FILE" ]]; then
            lock_list_calls="$(cat "$AZ_LOCK_STATE_FILE")"
        fi
        if [[ "$lock_list_calls" -eq 0 ]]; then
            printf '%s\n' "${AZ_LOCKS_BEFORE:-}"
        else
            printf '%s\n' "${AZ_LOCKS_AFTER:-}"
        fi
        echo $((lock_list_calls + 1)) >"$AZ_LOCK_STATE_FILE"
        ;;
    "lock delete")
        if [[ "${AZ_LOCK_DELETE_EXIT_CODE:-0}" -ne 0 ]]; then
            echo "AuthorizationFailed: Microsoft.Authorization/locks/delete is not allowed." >&2
            exit "$AZ_LOCK_DELETE_EXIT_CODE"
        fi
        ;;
esac
EOF
chmod +x "$MOCK_BIN/az"

cat >"$MOCK_BIN/openssl" <<'EOF'
#!/bin/bash
echo "mock-generated-password"
EOF
chmod +x "$MOCK_BIN/openssl"

cat >"$MOCK_BIN/sleep" <<'EOF'
#!/bin/bash
echo "sleep $*" >>"$CALL_LOG"
case "$*" in
    10|20) ;;
    *) exec "$REAL_SLEEP" "$@" ;;
esac
EOF
chmod +x "$MOCK_BIN/sleep"

run_lib() {
    (
        # shellcheck disable=SC2030 # PATH is intentionally scoped to this fixture subshell.
        export PATH="$MOCK_BIN:$PATH"
        export CALL_LOG
        unset RTC_LIB_RECIPE_TEST_SOURCED
        # shellcheck source=/dev/null
        source "$REPO_ROOT/.github/scripts/lib-recipe-test.sh"
        "$@"
    )
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [[ "$expected" == "$actual" ]] || fail "$label: expected [$expected] got [$actual]"
}

# rtc_resolve_environment_path returns "<path>\t<namespace>" on success.
: >"$CALL_LOG"
actual="$(ENV_NAMESPACE="my-ns" run_lib rtc_resolve_environment_path myenv myws)"
expected=$'/planes/radius/local/resourceGroups/default/providers/Applications.Core/environments/myenv\tmy-ns'
assert_eq "$expected" "$actual" "rtc_resolve_environment_path success"

# rtc_resolve_environment_path surfaces a failure from `rad env show`.
if ENV_SHOW_FAIL=1 run_lib rtc_resolve_environment_path myenv myws >/dev/null 2>&1; then
    fail "rtc_resolve_environment_path should fail when rad env show fails"
fi

# rtc_cleanup_kubernetes_resources is a no-op for an empty namespace, and
# invokes kubectl delete for each resource kind otherwise.
: >"$CALL_LOG"
run_lib rtc_cleanup_kubernetes_resources "" testapp
[[ -s "$CALL_LOG" ]] && fail "rtc_cleanup_kubernetes_resources should not call kubectl for an empty namespace"

: >"$CALL_LOG"
run_lib rtc_cleanup_kubernetes_resources "my-ns" testapp
kubectl_calls="$(grep -c '^kubectl delete' "$CALL_LOG" || true)"
assert_eq "3" "$kubectl_calls" "rtc_cleanup_kubernetes_resources kubectl delete call count"
grep -q -- '-l radapp.io/application=testapp -n my-ns' "$CALL_LOG" ||
    fail "cleanup must select only the test app"
if grep -q -- '--all' "$CALL_LOG"; then
    fail "cleanup must not delete shared namespace resources"
fi

# rtc_assert_recipe_result dispatches to the containers-specific assertion
# and detects two distinct hosts as success.
run_lib rtc_assert_recipe_result "Radius.Compute/containers" testapp myws >/dev/null \
    || fail "rtc_assert_recipe_result should pass when containers hosts differ"

# ... and to the postgresql-specific assertion.
run_lib rtc_assert_recipe_result "Radius.Data/postgreSqlDatabases" testapp myws >/dev/null \
    || fail "rtc_assert_recipe_result should pass for a valid postgresql result"

if PEER_HOST=host-a run_lib rtc_assert_recipe_result "Radius.Compute/containers" testapp myws >/dev/null; then
    fail "equal container hosts must fail"
fi
for invalid_result in \
    '{"properties":{}}' \
    '{"properties":{"hosts":{}}}' \
    '{"properties":{"hosts":{"orderProcessor":"","simple":""}}}'; do
    if CONTAINERS_JSON="$invalid_result" run_lib rtc_assert_recipe_result "Radius.Compute/containers" testapp myws >/dev/null; then
        fail "missing or empty container hosts must fail"
    fi
done
for invalid_result in \
    '{"properties":{"host":"","port":5432,"database":"appdb"}}' \
    '{"properties":{"host":"pg","port":"5432","database":"appdb"}}' \
    '{"properties":{"host":"pg","port":5432,"database":"wrong"}}' \
    '{"properties":{"host":"pg","port":5432,"database":"appdb","secrets":{}}}'; do
    if POSTGRES_JSON="$invalid_result" run_lib rtc_assert_recipe_result "Radius.Data/postgreSqlDatabases" testapp myws >/dev/null; then
        fail "invalid PostgreSQL output must fail the real jq assertion"
    fi
done

if WORKSPACE_EXIT_CODE=1 run_lib rtc_ensure_workspace_context myws >/dev/null 2>&1; then
    fail "workspace errors must not be ignored"
fi
for invalid_env in '{}' '[]' 'not json'; do
    if ENV_JSON="$invalid_env" run_lib rtc_resolve_environment_path myenv myws >/dev/null 2>&1; then
        fail "invalid environment output must fail"
    fi
done
actual="$(ENV_JSON='[{"id":"/envs/array-env"}]' run_lib rtc_resolve_environment_path myenv myws)"
assert_eq $'/envs/array-env\t' "$actual" "array environment output"

# ... and is a no-op success for any other Resource Type.
run_lib rtc_assert_recipe_result "Radius.Data/somethingElse" testapp myws \
    || fail "rtc_assert_recipe_result should default to success for an unknown type"

# rtc_deploy_and_assert_test_app: successful deploy path cleans up the app
# and any leftover K8s resources, with no error.
TEST_APP_BICEP="$TEST_ROOT/app.bicep"
printf '%s\n' "param environment string" "param applicationName string" >"$TEST_APP_BICEP"
: >"$CALL_LOG"
DEPLOY_EXIT_CODE=0 run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_BICEP" "Radius.Data/somethingElse" "rtc-test" "/envs/myenv" "myws" "my-ns" \
    || fail "rtc_deploy_and_assert_test_app should succeed when rad deploy succeeds"
grep -q '^rad app delete' "$CALL_LOG" || fail "rtc_deploy_and_assert_test_app should delete the app on success"
assert_eq "1" "$(grep -c '^rad deploy ' "$CALL_LOG")" "successful deployment attempt count"
assert_app_name() {
    local deployed_name
    deployed_name="$(sed -nE 's/^rad deploy .*--parameters applicationName=([^ ]+).*/\1/p' "$CALL_LOG")"
    [[ -n "$deployed_name" ]] || fail "deployment must pass the applicationName parameter"
    grep -Fq -- "--application $deployed_name --workspace myws" "$CALL_LOG" || fail "CLI app must match the template parameter"
    grep -Fxq "rad app delete $deployed_name --workspace myws --yes" "$CALL_LOG" || fail "cleanup must delete the deployed app"
    grep -Fq -- "-l radapp.io/application=$deployed_name -n my-ns" "$CALL_LOG" || fail "cleanup selector must match the deployed app"
}
assert_app_name

# ... failed deploy path still cleans up, but returns non-zero.
: >"$CALL_LOG"
if DEPLOY_EXIT_CODE=1 run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_BICEP" "Radius.Data/somethingElse" "rtc-test" "/envs/myenv" "myws" "my-ns" >/dev/null 2>&1; then
    fail "rtc_deploy_and_assert_test_app should fail when rad deploy fails"
fi
grep -q '^rad app delete' "$CALL_LOG" || fail "rtc_deploy_and_assert_test_app should still attempt app cleanup after a failed deploy"
assert_eq "1" "$(grep -c '^rad deploy ' "$CALL_LOG")" "ordinary failure attempt count"
assert_app_name

PREEXISTING_LOCK="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Authorization/locks/existing"
NEW_LOCK="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Cache/redis/cache/providers/Microsoft.Authorization/locks/new"
UNRELATED_LOCK="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/unrelated/providers/Microsoft.Authorization/locks/new"
LOCK_INVENTORY_JSON="[{\"properties\":{\"status\":{\"outputResources\":[{\"id\":\"/planes/azure/azurecloud$NEW_LOCK\",\"localID\":\"lock\",\"radiusManaged\":true}]}}}]"
PREEXISTING_LOCK_INVENTORY_JSON="[{\"properties\":{\"status\":{\"outputResources\":[{\"id\":\"/planes/azure/azurecloud$PREEXISTING_LOCK\",\"localID\":\"lock\",\"radiusManaged\":true}]}}}]"
export AZ_LOCK_STATE_FILE="$TEST_ROOT/az-lock-state"

# The Azure Recipe Pack guard ignores locks that existed before the entry.
: >"$CALL_LOG"
rm -f "$AZ_LOCK_STATE_FILE"
AZURE_RESOURCE_GROUP=rg AZURE_SUBSCRIPTION_ID=sub RTC_AZURE_LOCK_GUARD=1 \
    AZ_LOCKS_BEFORE="$PREEXISTING_LOCK" AZ_LOCKS_AFTER="$PREEXISTING_LOCK" RESOURCE_LIST_JSON="$PREEXISTING_LOCK_INVENTORY_JSON" \
    run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_BICEP" "Radius.Data/somethingElse" rtc-test /envs/myenv myws my-ns ||
    fail "pre-existing Azure locks must not fail the test"
if grep -q '^az lock delete' "$CALL_LOG"; then
    fail "pre-existing Azure locks must not be deleted"
fi

# A newly created lock that the test identity can delete does not cause a false failure.
: >"$CALL_LOG"
rm -f "$AZ_LOCK_STATE_FILE"
AZURE_RESOURCE_GROUP=rg AZURE_SUBSCRIPTION_ID=sub RTC_AZURE_LOCK_GUARD=1 \
    AZ_LOCKS_BEFORE="$PREEXISTING_LOCK" AZ_LOCKS_AFTER="$PREEXISTING_LOCK"$'\n'"$NEW_LOCK" \
    RESOURCE_LIST_JSON="$LOCK_INVENTORY_JSON" \
    run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_BICEP" "Radius.Data/somethingElse" rtc-test /envs/myenv myws my-ns ||
    fail "a deletable new Azure lock must not fail the test"
grep -Fq "az lock delete --ids $NEW_LOCK --subscription sub" "$CALL_LOG" ||
    fail "the new Azure lock must be deleted"
grep -q '^rad app delete' "$CALL_LOG" ||
    fail "normal Radius app cleanup must continue after deleting the new lock"

# An undeletable new lock fails before the slow Radius app deletion path.
: >"$CALL_LOG"
rm -f "$AZ_LOCK_STATE_FILE"
if output=$(AZURE_RESOURCE_GROUP=rg AZURE_SUBSCRIPTION_ID=sub RTC_AZURE_LOCK_GUARD=1 \
    AZ_LOCKS_BEFORE="$PREEXISTING_LOCK" AZ_LOCKS_AFTER="$PREEXISTING_LOCK"$'\n'"$NEW_LOCK" \
    RESOURCE_LIST_JSON="$LOCK_INVENTORY_JSON" AZ_LOCK_DELETE_EXIT_CODE=1 run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_BICEP" "Radius.Data/somethingElse" rtc-test /envs/myenv myws my-ns 2>&1); then
    fail "an undeletable new Azure lock must fail the test"
fi
grep -Fq "New Azure management lock could not be deleted: $NEW_LOCK" <<<"$output" ||
    fail "the failure must identify the new Azure lock"
grep -Fq "Affected Azure resource: ${NEW_LOCK%/providers/Microsoft.Authorization/locks/*}" <<<"$output" ||
    fail "the failure must identify the affected Azure resource"
grep -Fq "Microsoft.Authorization/locks/delete" <<<"$output" ||
    fail "the failure must name the required Azure permission"
if grep -q '^rad app delete' "$CALL_LOG"; then
    fail "the slow Radius app deletion path must not run while a new lock remains"
fi
bounded_cleanup_calls="$(grep -c '^kubectl delete .*--request-timeout=10s --wait=false$' "$CALL_LOG" || true)"
assert_eq "3" "$bounded_cleanup_calls" "undeletable lock bounded Kubernetes cleanup call count"

# A new lock outside the test application's Radius inventory remains untouched.
: >"$CALL_LOG"
rm -f "$AZ_LOCK_STATE_FILE"
AZURE_RESOURCE_GROUP=rg AZURE_SUBSCRIPTION_ID=sub RTC_AZURE_LOCK_GUARD=1 \
    AZ_LOCKS_BEFORE="" AZ_LOCKS_AFTER="$UNRELATED_LOCK" RESOURCE_LIST_JSON="[]" \
    run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_BICEP" "Radius.Data/somethingElse" rtc-test /envs/myenv myws my-ns ||
    fail "an unrelated new Azure lock must not fail the test"
if grep -q '^az lock delete' "$CALL_LOG"; then
    fail "an unrelated new Azure lock must not be deleted"
fi
grep -q '^rad app delete' "$CALL_LOG" ||
    fail "normal Radius app cleanup must continue when an unrelated lock is ignored"

# Radius can record a lock output even when Azure does not list the lock.
: >"$CALL_LOG"
rm -f "$AZ_LOCK_STATE_FILE"
if output=$(AZURE_RESOURCE_GROUP=rg AZURE_SUBSCRIPTION_ID=sub RTC_AZURE_LOCK_GUARD=1 \
    AZ_LOCKS_BEFORE="" AZ_LOCKS_AFTER="" RESOURCE_LIST_JSON="$LOCK_INVENTORY_JSON" \
    RTC_AZURE_DIAGNOSTICS_DIR="$TEST_ROOT/lock-diagnostics" \
    run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_BICEP" "Radius.Data/somethingElse" rtc-test /envs/myenv myws my-ns 2>&1); then
    fail "an inventory-only Azure lock must fail the test"
fi
grep -Fq "Radius recorded an Azure management lock that Azure did not list" <<<"$output" ||
    fail "the inventory-only failure must explain the Azure mismatch"
grep -Fq "Unexpected Radius output resource: $NEW_LOCK" <<<"$output" ||
    fail "the inventory-only failure must identify the lock"
if grep -q 'Grant the test identity' <<<"$output"; then
    fail "an inventory mismatch must not be reported as a permission failure"
fi
lock_report="$(find "$TEST_ROOT/lock-diagnostics" -name locks.json)"
jq -e --arg lock "$NEW_LOCK" '
    .azureLocksBefore == [] and .azureLocksAfter == [] and
    .radiusLockInventory == [$lock] and (.app | startswith("rtc-test-"))
' "$lock_report" >/dev/null || fail "inventory mismatch evidence must persist"
if grep -q '^rad app delete' "$CALL_LOG"; then
    fail "Radius app deletion must not run for an inventory-only lock"
fi

# Healthy Azure cleanup is not subject to a short harness timeout.
: >"$CALL_LOG"
rm -f "$AZ_LOCK_STATE_FILE"
started_at="$(date +%s)"
AZURE_RESOURCE_GROUP=rg AZURE_SUBSCRIPTION_ID=sub RTC_AZURE_LOCK_GUARD=1 \
    AZ_LOCKS_BEFORE="" AZ_LOCKS_AFTER="" RESOURCE_LIST_JSON="[]" \
    APP_DELETE_DELAY_SECONDS=1 \
    run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_BICEP" "Radius.Data/somethingElse" rtc-test /envs/myenv myws my-ns ||
    fail "a healthy delayed Azure cleanup must succeed"
elapsed=$(( $(date +%s) - started_at ))
[[ "$elapsed" -ge 1 ]] ||
    fail "the fixture must wait for the delayed Radius application deletion"
grep -q '^rad app delete' "$CALL_LOG" ||
    fail "healthy Azure cleanup must call Radius application deletion directly"
if grep -q '^timeout ' "$CALL_LOG"; then
    fail "healthy Azure cleanup must not use a short timeout"
fi

for failure in APP_DELETE_EXIT_CODE KUBECTL_EXIT_CODE; do
    if (
        export "$failure=1"
        run_lib rtc_deploy_and_assert_test_app \
            "$TEST_APP_BICEP" "Radius.Data/somethingElse" rtc-test /envs/myenv myws my-ns
    ) >/dev/null 2>&1; then
        fail "$failure must cause the test to fail"
    fi
done

: >"$CALL_LOG"
if POSTGRES_JSON='{"properties":{}}' run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_BICEP" "Radius.Data/postgreSqlDatabases" rtc-test /envs/myenv myws my-ns >/dev/null; then
    fail "post-deploy assertion failure must fail the test"
fi
grep -q '^rad app delete' "$CALL_LOG" || fail "assertion failure must still clean up"
assert_eq "1" "$(grep -c '^rad deploy ' "$CALL_LOG")" "assertion failure deployment attempt count"

: >"$CALL_LOG"
if CONTAINERS_JSON='{"properties":{}}' run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_BICEP" Radius.Compute/containers rtc-test /envs/myenv myws my-ns >/dev/null; then
    fail "a deployed ACI recipe without hosts must fail the test"
fi
assert_eq "1" "$(grep -c '^rad deploy ' "$CALL_LOG")" "missing hosts must not retry deployment"
assert_eq "1" "$(grep -c '^rad app delete ' "$CALL_LOG")" "missing hosts must clean up the application"
assert_app_name

# ... a template with a `password` parameter auto-generates one instead of
# passing a literal "password" placeholder through to `rad deploy`.
TEST_APP_WITH_PASSWORD="$TEST_ROOT/app-with-password.bicep"
printf '%s\n' "param applicationName string" "param password string" >"$TEST_APP_WITH_PASSWORD"
: >"$CALL_LOG"
DEPLOY_EXIT_CODE=0 run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_WITH_PASSWORD" "Radius.Data/somethingElse" "rtc-test" "/envs/myenv" "myws" "my-ns" >/dev/null \
    || fail "rtc_deploy_and_assert_test_app should succeed with an auto-generated password"
grep -Fq -- '--parameters password=Aa1!mock-generated-password' "$CALL_LOG" \
    || fail "rtc_deploy_and_assert_test_app should pass a generated password value to rad deploy"

# Retry only the Azure deployment-engine transport failure seen in Actions.
TRANSIENT_DEPLOY_ERROR='Error: {"code":"ResourceDeploymentFailure","message":"System.IO.IOException: Connection reset by peer","target":"/subscriptions/test/resourceGroups/test/providers/Microsoft.KeyVault/vaults/test"}'
DEPLOY_LOG_DIR="$TEST_ROOT/deploy-logs"
mkdir -p "$DEPLOY_LOG_DIR"
for failures in 1 2 3; do
    : >"$CALL_LOG"
    retry_status=0
    TMPDIR="$DEPLOY_LOG_DIR" DEPLOY_FAILURES="$failures" DEPLOY_ERROR="$TRANSIENT_DEPLOY_ERROR" \
        run_lib rtc_deploy_and_assert_test_app \
        "$TEST_APP_WITH_PASSWORD" Radius.Security/secrets rtc-test /envs/myenv myws my-ns \
        --parameters location=test-location >"$TEST_ROOT/retry-output" 2>&1 || retry_status=$?
    if [[ "$failures" -lt 3 ]]; then
        assert_eq "0" "$retry_status" "transient failure recovery"
        expected_attempts=$((failures + 1))
    else
        [[ "$retry_status" -ne 0 ]] || fail "exhausted retries must fail"
        expected_attempts=3
    fi
    assert_eq "$expected_attempts" "$(grep -c '^rad deploy ' "$CALL_LOG")" "bounded deployment attempts"
    assert_eq "$((expected_attempts - 1))" "$(grep -c '^sleep ' "$CALL_LOG")" "retry delay count"
    grep -Fxq 'sleep 10' "$CALL_LOG" || fail "first retry must back off for 10 seconds"
    if [[ "$expected_attempts" -eq 3 ]]; then
        grep -Fxq 'sleep 20' "$CALL_LOG" || fail "second retry must back off for 20 seconds"
    fi
    assert_eq "1" "$(grep '^rad deploy ' "$CALL_LOG" | sort -u | wc -l | tr -d ' ')" \
        "retries must preserve all deployment arguments, including generated credentials"
    assert_eq "1" "$(grep -c '^rad app delete ' "$CALL_LOG")" "cleanup after retries"
    awk '/^rad app delete / { cleaned = 1 } /^rad deploy / && cleaned { exit 1 }' "$CALL_LOG" ||
        fail "cleanup must not run between deployment attempts"
    grep -Fq 'Connection reset by peer' "$TEST_ROOT/retry-output" || fail "deployment diagnostics must remain visible"
    [[ -z "$(find "$DEPLOY_LOG_DIR" -type f -print -quit)" ]] || fail "deployment transcripts must be removed"
done

# A successful Azure operation must not qualify an unrelated failure for retries.
MIXED_DEPLOY_ERROR='Deployment operations:
{"status":"Succeeded","target":"/subscriptions/test/resourceGroups/test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/test"}
Error: {
  "code": "ResourceDeploymentFailure",
  "message": "Connection reset by peer",
  "target": "/planes/radius/local/resourceGroups/test/providers/Radius.Data/widgets/test"
}'

for deploy_error in \
    'InvalidTemplate: invalid property' \
    'AuthorizationFailed: access denied' \
    "$MIXED_DEPLOY_ERROR" \
    '{"code":"ResourceDeploymentFailure","message":"VaultAlreadyExists","target":"/subscriptions/test/resourceGroups/test/providers/Microsoft.KeyVault/vaults/test","details":[{"message":"Connection reset by peer"}]}' \
    '{"code":"ResourceDeploymentFailure","message":"VaultAlreadyExists","target":"/subscriptions/test/resourceGroups/test/providers/Microsoft.KeyVault/vaults/test"}' \
    'Connection reset by peer' \
    '{"code":"ResourceDeploymentFailure","message":"Connection reset by peer","target":"/planes/radius/local/resourceGroups/test/providers/Radius.Data/widgets/test"}'; do
    : >"$CALL_LOG"
    if DEPLOY_EXIT_CODE=1 DEPLOY_ERROR="$deploy_error" run_lib rtc_deploy_and_assert_test_app \
        "$TEST_APP_BICEP" Radius.Security/secrets rtc-test /envs/myenv myws my-ns >/dev/null 2>&1; then
        fail "non-retryable errors must fail"
    fi
    assert_eq "1" "$(grep -c '^rad deploy ' "$CALL_LOG")" "non-retryable deployment attempt count"
    grep -q '^sleep ' "$CALL_LOG" && fail "non-retryable errors must not back off"
    grep -q '^rad app delete ' "$CALL_LOG" || fail "non-retryable failures must still clean up"
done

: >"$CALL_LOG"
DEPLOY_FAILURES=1 DEPLOY_ERROR='Deploying resources...
Error: {"code":"DeploymentFailed","details":[{
  "target": "/subscriptions/test/resourceGroups/test/providers/Microsoft.KeyVault/vaults/test",
  "message": "System.IO.IOException: Connection reset by peer (\"{transport}\")",
  "code": "ResourceDeploymentFailure",
  "details": []
}]}
Deployment failed.' run_lib rtc_deploy_with_retry "$TEST_APP_BICEP" >/dev/null 2>&1 ||
    fail "nested multiline Azure connection-reset errors must retry"
assert_eq "2" "$(grep -c '^rad deploy ' "$CALL_LOG")" "nested Azure failure attempt count"

: >"$CALL_LOG"
if DEPLOY_EXIT_CODE=1 DEPLOY_ERROR="$TRANSIENT_DEPLOY_ERROR" DEPLOY_ERROR_AFTER_FIRST='InvalidTemplate: invalid property' \
    run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_BICEP" Radius.Security/secrets rtc-test /envs/myenv myws my-ns >/dev/null 2>&1; then
    fail "permanent errors after a transient failure must fail"
fi
assert_eq "2" "$(grep -c '^rad deploy ' "$CALL_LOG")" "only the latest failure may trigger a retry"

: >"$CALL_LOG"
if APP_DELETE_EXIT_CODE=1 DEPLOY_FAILURES=1 DEPLOY_ERROR="$TRANSIENT_DEPLOY_ERROR" \
    run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_BICEP" Radius.Security/secrets rtc-test /envs/myenv myws my-ns >/dev/null 2>&1; then
    fail "cleanup failures after recovery must still fail"
fi
assert_eq "2" "$(grep -c '^rad deploy ' "$CALL_LOG")" "cleanup must not trigger deployment retries"

# Exercise the real SQL Server template, not a fixture with fewer parameters.
: >"$CALL_LOG"
run_lib rtc_deploy_and_assert_test_app \
    "$REPO_ROOT/Data/sqlServerDatabases/test/app.bicep" "Radius.Data/sqlServerDatabases" rtc-test /envs/myenv myws my-ns >/dev/null ||
    fail "SQL Server test template must accept generated credentials"
grep -Fq -- '--parameters password=Aa1!mock-generated-password' "$CALL_LOG" ||
    fail "SQL Server must receive a generated password"
assert_app_name
grep -q "^param username string = 'radadmin'$" "$REPO_ROOT/Data/sqlServerDatabases/test/app.bicep" ||
    fail "SQL Server must provide a non-secret username default"
grep -A1 '^@secure()' "$REPO_ROOT/Data/sqlServerDatabases/test/app.bicep" | grep -q '^param password string$' ||
    fail "SQL Server password must remain secure"

# The containers template must encode the runner's plain-text password before
# passing it to a Secret entry marked as base64.
container_password_entry="$(awk '
    /^resource secret / { in_secret = 1 }
    in_secret && /^[[:space:]]*password: \{/ { in_password = 1; next }
    in_password && /^[[:space:]]*\}/ { exit }
    in_password { print }
' "$REPO_ROOT/Compute/containers/test/app.bicep")"
grep -qE '^[[:space:]]*value: base64\(password\)$' <<<"$container_password_entry" ||
    fail "containers test must base64-encode the generated password"
grep -qE "^[[:space:]]*encoding: 'base64'$" <<<"$container_password_entry" ||
    fail "containers test must retain base64 Secret coverage"

# Azure retains deleted Key Vault names, so each secrets test application must
# derive a short, valid resource name from its unique application name.
secrets_resource_name="$(awk '
    /^resource .*Radius.Security\/secrets@/ { in_secret = 1; next }
    in_secret && /^  name:/ { print; exit }
' "$REPO_ROOT/Security/secrets/test/app.bicep")"
[[ "$secrets_resource_name" == "  name: 'dbsecret-\${take(uniqueString(applicationName), 8)}'" ]] ||
    fail "secrets test resource name must use an 8-character applicationName hash"

echo 'param environment string' >"$TEST_ROOT/missing-application-name.bicep"
: >"$CALL_LOG"
if run_lib rtc_deploy_and_assert_test_app "$TEST_ROOT/missing-application-name.bicep" \
    Radius.Data/widgets rtc-test /envs/myenv myws my-ns >/dev/null 2>&1; then
    fail "templates without the applicationName contract must fail before deployment"
fi
[[ ! -s "$CALL_LOG" ]] || fail "invalid template must not deploy or delete an application"

# Guard all current test apps, including the types used only by per-recipe CI.
while IFS= read -r template; do
    grep -q '^param applicationName string' "$template" || fail "$template needs an applicationName parameter"
    awk '
        /^resource .*Radius.Core\/applications@/ { app = 1; next }
        app && /^  name:/ { if ($0 != "  name: applicationName") exit 1; found++; app = 0 }
        END { if (found != 1) exit 1 }
    ' "$template" || fail "$template must use applicationName for its application"
done < <(find "$REPO_ROOT/AI" "$REPO_ROOT/Compute" "$REPO_ROOT/Data" "$REPO_ROOT/Messaging" \
    "$REPO_ROOT/Security" "$REPO_ROOT/Storage" -path '*/test/app.bicep' -type f)

# The existing per-recipe caller must preserve failure and cleanup behavior.
mkdir -p "$TEST_ROOT/Data/widgets/recipes/kubernetes/bicep" "$TEST_ROOT/Data/widgets/test"
touch "$TEST_ROOT/Data/widgets/recipes/kubernetes/bicep/main.bicep"
cp "$TEST_APP_BICEP" "$TEST_ROOT/Data/widgets/test/app.bicep"
run_recipe() {
    (
        cd "$TEST_ROOT"
        # shellcheck disable=SC2031 # This fixture creates a new subshell with the mock PATH.
        PATH="$MOCK_BIN:$PATH" CALL_LOG="$CALL_LOG" \
            bash "$REPO_ROOT/.github/scripts/test-recipe.sh" Data/widgets/recipes/kubernetes/bicep
    )
}
run_recipe >/dev/null || fail "existing per-recipe success path failed"
: >"$CALL_LOG"
if DEPLOY_EXIT_CODE=1 run_recipe >/dev/null; then
    fail "existing per-recipe deploy failure must fail"
fi
grep -q '^rad app delete' "$CALL_LOG" || fail "per-recipe failure must still delete the test app"
if grep -q '^rad recipe ' "$CALL_LOG"; then
    fail "per-recipe failure must not call the removed 'rad recipe' command"
fi

POSTGRES_CAPACITY_ERROR='Error: {"code":"DeploymentFailed","details":[{"code":"ResourceDeploymentFailure","target":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/pg","message":"{\"code\":\"SkuNotAvailable\",\"message\":\"capacity unavailable\"}"}]}'
cat >"$MOCK_BIN/timeout" <<'EOF'
#!/bin/bash
echo "timeout $*" >>"$CALL_LOG"
if [[ "${POSTGRES_DEPLOY_TIMEOUT:-0}" == 1 && "$3" == bash ]]; then exit 124; fi
exec /usr/bin/timeout "$@"
EOF
chmod +x "$MOCK_BIN/timeout"
run_postgres() {
    AZURE_RESOURCE_GROUP=rg RTC_TEST_PLATFORM=azure run_lib rtc_test_azure_postgresql_app \
        "$TEST_APP_BICEP" /envs/myenv myws my-ns
}
: >"$CALL_LOG"
DEPLOY_FAILURES=1 DEPLOY_ERROR="$POSTGRES_CAPACITY_ERROR" run_postgres >/dev/null ||
    fail "PostgreSQL deploy-time capacity loss must recover"
assert_eq 2 "$(grep -c '^rad deploy ' "$CALL_LOG")" "PostgreSQL recovery attempts"
grep -q -- '--parameters postgresSize=S' "$CALL_LOG" || fail "first deployment must use S"
grep -q -- '--parameters postgresSize=M' "$CALL_LOG" || fail "recovery must use M"
assert_eq 2 "$(grep '^rad deploy ' "$CALL_LOG" | sed -E 's/.*applicationName=([^ ]+).*/\1/' | sort -u | wc -l | tr -d ' ')" \
    "recovery application names must be distinct"
awk '/^rad app delete / { cleaned++ } /^az resource list / { snapshots++ }
    /^rad deploy / { attempts++; if (attempts == 2 && (cleaned != 1 || snapshots < 3)) exit 1 }' "$CALL_LOG" ||
    fail "recovery must follow Radius cleanup and Azure deletion verification"

: >"$CALL_LOG"
DEPLOY_FAILURES=1 DEPLOY_ERROR="$POSTGRES_CAPACITY_ERROR" RTC_POSTGRES_TEST_SIZE=M run_postgres >/dev/null ||
    fail "an M selection must recover with untried S"
grep '^rad deploy ' "$CALL_LOG" | tail -1 | grep -q 'postgresSize=S' ||
    fail "M recovery must use S, not L (the same SKU)"

: >"$CALL_LOG"
if DEPLOY_EXIT_CODE=1 DEPLOY_ERROR="$POSTGRES_CAPACITY_ERROR" run_postgres >/dev/null 2>&1; then
    fail "capacity recovery exhaustion must fail"
fi
assert_eq 2 "$(grep -c '^rad deploy ' "$CALL_LOG")" "capacity recovery is limited to two attempts"

: >"$CALL_LOG"
DEPLOY_FAILURES=1 DEPLOY_ERROR="${POSTGRES_CAPACITY_ERROR//SkuNotAvailable/ServerIsBusy}" run_postgres >/dev/null ||
    fail "PostgreSQL ServerIsBusy must permit recovery"
assert_eq 2 "$(grep -c '^rad deploy ' "$CALL_LOG")" "ServerIsBusy recovery attempts"

for failure in \
    'SkuNotAvailable' \
    '{"code":"SkuNotAvailable","target":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm"}' \
    '{"code":"AuthorizationFailed","target":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/pg"}' \
    '{"code":"DeploymentFailed","details":[{"code":"ServerIsBusy","target":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/pg"},{"code":"AuthorizationFailed"}]}' \
    '{"code":"DeploymentFailed","details":[{"code":"ServerIsBusy","target":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/pg"},{"code":"ResourceDeploymentFailure","details":[]}]}' \
    '{"code":"UnknownError","message":"SkuNotAvailable"}'; do
    : >"$CALL_LOG"
    if DEPLOY_EXIT_CODE=1 DEPLOY_ERROR="$failure" run_postgres >/dev/null 2>&1; then
        fail "non-capacity or mixed errors must fail"
    fi
    assert_eq 1 "$(grep -c '^rad deploy ' "$CALL_LOG")" "non-capacity errors must not retry"
done

for failure in APP_DELETE_EXIT_CODE KUBECTL_EXIT_CODE AZ_RESOURCE_LIST_FAIL; do
    : >"$CALL_LOG"
    if (
        export "$failure=1"
        DEPLOY_FAILURES=1 DEPLOY_ERROR="$POSTGRES_CAPACITY_ERROR" run_postgres
    ) >/dev/null 2>&1; then fail "$failure must block recovery"; fi
    [[ "$(grep -c '^rad deploy ' "$CALL_LOG")" -le 1 ]] || fail "cleanup uncertainty must block recovery"
done
: >"$CALL_LOG"
if DEPLOY_EXIT_CODE=42 DEPLOY_ERROR='Unknown CLI failure' run_postgres >/dev/null 2>&1; then
    fail "a raw CLI exit code must not grant capacity recovery"
fi
assert_eq 1 "$(grep -c '^rad deploy ' "$CALL_LOG")" "raw exit 42 is not evidence of capacity"
: >"$CALL_LOG"
if DEPLOY_FAILURES=1 DEPLOY_ERROR="$POSTGRES_CAPACITY_ERROR" \
    AZ_RESOURCES_AFTER='[{"id":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/leftover"}]' \
    run_postgres >/dev/null 2>&1; then fail "leftover Azure resources must block recovery"; fi
assert_eq 1 "$(grep -c '^rad deploy ' "$CALL_LOG")" "leftover resource must block new allocation"

: >"$CALL_LOG"
if POSTGRES_JSON='{"properties":{}}' run_postgres >/dev/null 2>&1; then fail "assertion failure must fail"; fi
assert_eq 1 "$(grep -c '^rad deploy ' "$CALL_LOG")" "assertion failure must not change size"
: >"$CALL_LOG"
if RTC_POSTGRES_TEST_DEADLINE_EPOCH=1 run_postgres >/dev/null 2>&1; then fail "expired deadline must fail"; fi
[[ ! -s "$CALL_LOG" ]] || fail "deadline must stop allocation"

: >"$CALL_LOG"
if POSTGRES_DEPLOY_TIMEOUT=1 run_postgres >/dev/null 2>&1; then fail "deploy timeout must fail"; fi
assert_eq 1 "$(grep -c '^timeout .* bash -c ' "$CALL_LOG")" "timeout must not change size"
assert_eq 1 "$(grep -c '^rad app delete ' "$CALL_LOG")" "timeout must still clean up"
: >"$CALL_LOG"
RTC_POSTGRES_TEST_DEADLINE_EPOCH="$(( $(date +%s) + 45 ))" run_postgres >/dev/null ||
    fail "a remaining deadline must permit a bounded deployment"
limit="$(sed -nE 's/^timeout --kill-after=5s ([0-9]+)s bash .*/\1/p' "$CALL_LOG")"
[[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 && "$limit" -le 45 ]] ||
    fail "deployment must respect remaining selection time"

# Exercise the actual single-entry caller with the same mock cloud commands.
run_postgres_entry() {
    (
        cd "$REPO_ROOT"
        # shellcheck disable=SC2031 # This fixture sets PATH in its own subshell.
        PATH="$MOCK_BIN:$PATH" CALL_LOG="$CALL_LOG" \
            bash .github/scripts/test-recipe-pack-entry.sh Data/postgreSqlDatabases myws myenv
    )
}
: >"$CALL_LOG"
RTC_TEST_PLATFORM=azure AZURE_RESOURCE_GROUP=rg RTC_POSTGRES_TEST_SIZE=M \
    run_postgres_entry >/dev/null || fail "single-entry Azure runner must pass selected M"
grep -q -- '--parameters postgresSize=M' "$CALL_LOG" || fail "single-entry runner must pass M to Bicep"
: >"$CALL_LOG"
RTC_TEST_PLATFORM=kubernetes RTC_POSTGRES_TEST_SIZE=M run_postgres_entry >/dev/null ||
    fail "Kubernetes entry must retain the default template size"
if grep -q 'postgresSize=' "$CALL_LOG"; then fail "Kubernetes must not get an Azure size override"; fi
grep -q "^param postgresSize string = 'S'$" "$REPO_ROOT/Data/postgreSqlDatabases/test/app.bicep" ||
    fail "test template default must remain S"

echo "Recipe test library test passed"
