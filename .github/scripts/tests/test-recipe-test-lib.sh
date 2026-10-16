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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-recipe-test-lib-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN"
TEST_PATH="$MOCK_BIN:$PATH"
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
        rm -f "$CALL_LOG.deleted"
        for ((i=1; i<$#; i++)); do
            if [[ "${!i}" == --application ]]; then
                next=$((i+1))
                echo "${!next}" > "$CALL_LOG.app"
            fi
        done
        exit "${DEPLOY_EXIT_CODE:-0}"
        ;;
    "resource-type list")
        if [[ -n "${CATALOG_JSON+x}" ]]; then
            printf '%s\n' "$CATALOG_JSON"
        else
            echo '[{"Name":"Radius.Data/widgets"},{"Name":"Radius.Core/applications"},{"Name":"Radius.Core/environments"},{"Name":"Microsoft.Resources/deployments"}]'
        fi
        exit "${CATALOG_EXIT_CODE:-0}"
        ;;
    "resource list")
        [[ "$3" == Radius.Data/widgets && " $* " == *" --preview "* ]] || exit 90
        [[ " $* " != *" --application "* && " $* " != *" --environment "* ]] || exit 90
        if [[ -n "${RESOURCE_JSON+x}" ]]; then
            printf '%s\n' "$RESOURCE_JSON"
        elif [[ "${RESOURCE_REMAINS:-0}" == 1 || "${OWNERSHIP_LOST:-0}" == 1 ]]; then
            app="$(cat "$CALL_LOG.app")"
            if [[ "${OWNERSHIP_LOST:-0}" == 1 && -f "$CALL_LOG.deleted" ]]; then
                app=another-app
            fi
            printf '[{"id":"/planes/radius/local/resourceGroups/default/providers/Radius.Data/widgets/fixture","properties":{"application":"/planes/radius/local/resourceGroups/default/providers/Radius.Core/applications/%s"}}]\n' "$app"
        else
            echo '[]'
        fi
        exit "${RESOURCE_LIST_EXIT_CODE:-0}"
        ;;
    "resource show")
        # Used by the containers/postgresql assertion helpers.
        case "$3" in
            "Radius.Compute/containers")
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
    "app delete")
        [[ " $* " == *" --preview "* ]] || { echo "Legacy application delete refused" >&2; exit 90; }
        echo "$3" > "$CALL_LOG.app"
        touch "$CALL_LOG.deleted"
        exit "${APP_DELETE_EXIT_CODE:-0}"
        ;;
    "app list")
        [[ " $* " == *" --preview "* ]] || { echo "Legacy application list refused" >&2; exit 90; }
        if [[ "${APP_REMAINS:-0}" == 1 ]]; then
            printf '[{"name":"%s"}]\n' "$(cat "$CALL_LOG.app")"
        else
            printf '%s\n' "${APP_LIST_JSON-[]}"
        fi
        exit "${APP_LIST_EXIT_CODE:-0}"
        ;;
    *)
        echo "Unexpected rad command: $1 $2" >&2
        exit 90
        ;;
esac
EOF
chmod +x "$MOCK_BIN/rad"

cat >"$MOCK_BIN/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >>"$CALL_LOG"
[[ "${KUBECTL_EXIT_CODE:-0}" == 0 ]] || exit "$KUBECTL_EXIT_CODE"
if [[ "$1" == get ]]; then
    if [[ " $* " == *" --all-namespaces "* ]]; then
        [[ "${DISCOVERY_EXIT_CODE:-0}" == 0 ]] || exit "$DISCOVERY_EXIT_CODE"
        if [[ -n "${DISCOVERY_JSON:-}" ]]; then
            printf '%s\n' "$DISCOVERY_JSON"
        else
            for arg in "$@"; do
                [[ "$arg" != radapp.io/application=* ]] || app="${arg#*=}"
            done
            printf '{"items":[{"metadata":{"namespace":"%s","labels":{"radapp.io/application":"%s"}}}]}\n' \
                "${ACTUAL_NAMESPACE:-my-ns}" "$app"
        fi
    else
        if [[ -n "${REMAINING_JSON+x}" ]]; then
            printf '%s\n' "$REMAINING_JSON"
        else
            echo '{"items":[]}'
        fi
        exit "${KUBECTL_GET_EXIT_CODE:-0}"
    fi
fi
exit "${KUBECTL_EXIT_CODE:-0}"
EOF
chmod +x "$MOCK_BIN/kubectl"

cat >"$MOCK_BIN/openssl" <<'EOF'
#!/bin/bash
echo "mock-generated-password"
EOF
chmod +x "$MOCK_BIN/openssl"

run_lib() {
    (
        export PATH="$TEST_PATH"
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
assert_eq "4" "$kubectl_calls" "rtc_cleanup_kubernetes_resources kubectl delete call count"
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
assert_app_name() {
    local deployed_name
    deployed_name="$(sed -nE 's/^rad deploy .*--parameters applicationName=([^ ]+).*/\1/p' "$CALL_LOG")"
    [[ -n "$deployed_name" ]] || fail "deployment must pass the applicationName parameter"
    grep -Fq -- "--application $deployed_name --workspace myws" "$CALL_LOG" || fail "CLI app must match the template parameter"
    grep -Fxq "rad app delete $deployed_name --workspace myws --preview --yes" "$CALL_LOG" || fail "cleanup must delete the modern deployed app"
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
assert_app_name

for failure in APP_DELETE_EXIT_CODE APP_LIST_EXIT_CODE APP_REMAINS KUBECTL_EXIT_CODE DISCOVERY_EXIT_CODE KUBECTL_GET_EXIT_CODE CATALOG_EXIT_CODE RESOURCE_LIST_EXIT_CODE RESOURCE_REMAINS OWNERSHIP_LOST; do
    if (
        export "$failure=1"
        run_lib rtc_deploy_and_assert_test_app \
            "$TEST_APP_BICEP" "Radius.Data/somethingElse" rtc-test /envs/myenv myws my-ns
    ) >/dev/null 2>&1; then
        fail "$failure must cause the test to fail"
    fi
done

APP_LIST_JSON=null run_lib rtc_cleanup_test_application testapp myws '' ||
    fail "successful JSON null application list is the CLI's empty result"
for malformed in false '{}' '[{}]' 'not json'; do
    if APP_LIST_JSON="$malformed" run_lib rtc_cleanup_test_application testapp myws '' >/dev/null 2>&1; then
        fail "invalid application list must not prove absence: $malformed"
    fi
done
for malformed in null '{}' '[{"name":"Radius.Data/widgets"}]' 'not json'; do
    if CATALOG_JSON="$malformed" run_lib rtc_cleanup_test_application testapp myws '' >/dev/null 2>&1; then
        fail "invalid resource catalog must fail verification"
    fi
done
for malformed in null '{}' '[{}]' 'not json'; do
    if RESOURCE_JSON="$malformed" run_lib rtc_cleanup_test_application testapp myws '' >/dev/null 2>&1; then
        fail "invalid typed resource list must fail verification"
    fi
done
RESOURCE_JSON='[{"id":"/planes/radius/local/resourceGroups/default/providers/Radius.Data/widgets/unrelated","properties":{"application":"/planes/radius/local/resourceGroups/other/providers/Radius.Core/applications/testapp"}}]' \
    run_lib rtc_cleanup_test_application testapp myws '' ||
    fail "same application name in another scope must not be treated as owned"
if APP_LIST_JSON=null RESOURCE_JSON='[{"id":"/planes/radius/local/resourceGroups/default/providers/Radius.Data/widgets/orphan","properties":{"application":"/PLANES/RADIUS/LOCAL/RESOURCEGROUPS/DEFAULT/PROVIDERS/RADIUS.CORE/APPLICATIONS/TESTAPP"}}]' \
    run_lib rtc_cleanup_test_application testapp myws '' >/dev/null 2>&1; then
    fail "missing app with remaining owned resources must not pass cleanup"
fi
if REMAINING_JSON='{"items":[{}]}' run_lib rtc_cleanup_test_application testapp myws my-ns >/dev/null 2>&1; then
    fail "leftover Kubernetes resources must fail cleanup"
fi
for malformed in '{}' '{"items":[{"metadata":{"namespace":"another-ns","labels":{"radapp.io/application":"another-app"}}}]}' 'not json'; do
    : >"$CALL_LOG"
    if DISCOVERY_JSON="$malformed" run_lib rtc_cleanup_test_application testapp myws configured-ns >/dev/null 2>&1; then
        fail "untrusted namespace discovery must fail cleanup"
    fi
    grep -q '^rad app delete' "$CALL_LOG" || fail "discovery failure must still attempt Radius cleanup"
    if grep -q '^kubectl delete' "$CALL_LOG"; then fail "discovery failure must not guess a namespace"; fi
done

: >"$CALL_LOG"
ACTUAL_NAMESPACE=runtime-ns run_lib rtc_cleanup_test_application testapp myws configured-ns ||
    fail "actual namespace may differ from configured namespace"
grep -q '^kubectl delete .* -n runtime-ns$' "$CALL_LOG" || fail "must clean up actual namespace"
if grep -q -- '-n configured-ns' "$CALL_LOG"; then fail "must not assume configured namespace"; fi
grep -q '^rad app list --workspace myws --preview -o json$' "$CALL_LOG" ||
    fail "cleanup must verify modern application absence"

: >"$CALL_LOG"
DISCOVERY_JSON='{"items":[]}' run_lib rtc_cleanup_test_application testapp myws configured-ns ||
    fail "partial deployment without workloads must clean up"
if grep -q '^kubectl delete' "$CALL_LOG"; then fail "empty discovery must not delete in a guessed namespace"; fi

# Exercise the actual transport runner's EXIT trap on its first failed deploy.
: >"$CALL_LOG"
if PATH="$TEST_PATH" CALL_LOG="$CALL_LOG" DEPLOY_EXIT_CODE=1 ACTUAL_NAMESPACE=runtime-ns \
    bash "$REPO_ROOT/.github/scripts/test-postgresql-transport.sh" \
        "$TEST_APP_BICEP" /envs/myenv myws configured-ns bicep >/dev/null 2>&1; then
    fail "transport runner must retain deployment failure"
fi
grep -q '^rad app delete postgresql-tls-.* --workspace myws --preview --yes$' "$CALL_LOG" ||
    fail "transport runner must use modern application cleanup"
grep -q '^kubectl delete .* -n runtime-ns$' "$CALL_LOG" ||
    fail "transport failure must discover the actual namespace before cleanup"

: >"$CALL_LOG"
if POSTGRES_JSON='{"properties":{}}' run_lib rtc_deploy_and_assert_test_app \
    "$TEST_APP_BICEP" "Radius.Data/postgreSqlDatabases" rtc-test /envs/myenv myws my-ns >/dev/null; then
    fail "post-deploy assertion failure must fail the test"
fi
grep -q '^rad app delete' "$CALL_LOG" || fail "assertion failure must still clean up"

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
        PATH="$TEST_PATH" CALL_LOG="$CALL_LOG" \
            bash "$REPO_ROOT/.github/scripts/test-recipe.sh" Data/widgets/recipes/kubernetes/bicep
    )
}
run_recipe >/dev/null || fail "existing per-recipe success path failed"
: >"$CALL_LOG"
if DEPLOY_EXIT_CODE=1 run_recipe >/dev/null; then
    fail "existing per-recipe deploy failure must fail"
fi
if grep -q '^rad recipe ' "$CALL_LOG"; then
    fail "pack-backed tests must not register or unregister a single recipe"
fi

echo "Recipe test library test passed"
