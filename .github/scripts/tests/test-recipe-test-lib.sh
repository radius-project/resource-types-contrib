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
        exit "${DEPLOY_EXIT_CODE:-0}"
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

cat >"$MOCK_BIN/openssl" <<'EOF'
#!/bin/bash
echo "mock-generated-password"
EOF
chmod +x "$MOCK_BIN/openssl"

run_lib() {
    (
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
assert_app_name

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
        PATH="$MOCK_BIN:$PATH" CALL_LOG="$CALL_LOG" \
            bash "$REPO_ROOT/.github/scripts/test-recipe.sh" Data/widgets/recipes/kubernetes/bicep
    )
}
run_recipe >/dev/null || fail "existing per-recipe success path failed"
: >"$CALL_LOG"
if DEPLOY_EXIT_CODE=1 run_recipe >/dev/null; then
    fail "existing per-recipe deploy failure must fail"
fi
grep -q '^rad recipe unregister default' "$CALL_LOG" || fail "per-recipe failure must unregister"

echo "Recipe test library test passed"
