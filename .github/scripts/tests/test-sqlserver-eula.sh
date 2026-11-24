#!/bin/bash

# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed
# under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
# CONDITIONS OF ANY KIND, either express or implied. See the License for the
# specific language governing permissions and limitations under the License.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-sqlserver-eula-XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
FIXTURE_ROOT="$TEST_ROOT/source"
GENERATOR="$REPO_ROOT/.github/scripts/generate-recipe-pack.sh"
RUNNER="$REPO_ROOT/.github/scripts/test-recipe.sh"
export COMMAND_CALLS="$TEST_ROOT/command-calls"
unset RTC_SQLSERVER_ACCEPT_EULA

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

with_consent() {
    local consent="$1"
    shift
    if [[ "$consent" == unset ]]; then
        env -u RTC_SQLSERVER_ACCEPT_EULA "$@"
    else
        env "RTC_SQLSERVER_ACCEPT_EULA=$consent" "$@"
    fi
}

for resource in sqlServerDatabases widgets; do
    for platform in kubernetes azure; do
        base="$FIXTURE_ROOT/Data/$resource"
        mkdir -p "$base/recipes/$platform/bicep" "$base/recipes/$platform/terraform" "$base/test"
        printf 'param context object\n' >"$base/recipes/$platform/bicep/main.bicep"
        printf 'variable "context" {}\n' >"$base/recipes/$platform/terraform/main.tf"
        printf 'param applicationName string\n' >"$base/test/app.bicep"
    done
done

for kind in bicep terraform; do
    output="$TEST_ROOT/$kind.bicep"
    for consent in unset "" N Y invalid; do
        (
            if with_consent "$consent" env RECIPE_PLATFORM_FILTER=kubernetes bash "$GENERATOR" "$FIXTURE_ROOT" "${kind}recipepack" "$output" >"$TEST_ROOT/generator.log" 2>&1; then
                [[ "$consent" != invalid ]] || fail "Generator accepted invalid consent"
            else
                [[ "$consent" == invalid ]] || fail "Generator rejected valid consent state"
                grep -Fq 'Error: RTC_SQLSERVER_ACCEPT_EULA must be' "$TEST_ROOT/generator.log" ||
                    fail "Generator omitted the invalid-consent error"
                exit 0
            fi
            grep -Fq "'Radius.Data/widgets': {" "$output" || fail "Unrelated Kubernetes Recipe was removed"
            if [[ "$consent" == Y ]]; then
                grep -Fq "'Radius.Data/sqlServerDatabases': {" "$output" || fail "Opted-in SQL Server Recipe is absent"
                grep -Fq "sqlServerAcceptEula: 'Y'" "$output" || fail "Opted-in Recipe lacks the required parameter"
                ! grep -Fq 'Skipping SQL Server' "$TEST_ROOT/generator.log" || fail "Opt-in was reported as skipped"
            else
                ! grep -Fq "'Radius.Data/sqlServerDatabases': {" "$output" || fail "Generator included SQL Server without consent"
                ! grep -Fq 'sqlServerAcceptEula' "$output" || fail "Generator supplied consent without operator opt-in"
                grep -Fq 'Skipping SQL Server Kubernetes Recipe: no operator EULA consent' "$TEST_ROOT/generator.log" ||
                    fail "Generator did not explain the skip"
            fi
        )
    done

    RTC_SQLSERVER_ACCEPT_EULA=invalid RECIPE_PLATFORM_FILTER=azure \
        bash "$GENERATOR" "$FIXTURE_ROOT" "${kind}recipepack" "$output" >"$TEST_ROOT/generator.log" 2>&1
    grep -Fq "'Radius.Data/sqlServerDatabases': {" "$output" || fail "Azure SQL Recipe was gated"
    ! grep -Fq 'sqlServerAcceptEula' "$output" || fail "Kubernetes license parameter leaked to Azure"

    only_sql="$TEST_ROOT/only-sql/Data/sqlServerDatabases/recipes/kubernetes/$kind"
    mkdir -p "$only_sql"
    if [[ "$kind" == bicep ]]; then touch "$only_sql/main.bicep"; else touch "$only_sql/main.tf"; fi
    printf 'stale\n' >"$output"
    RECIPE_PLATFORM_FILTER=kubernetes bash "$GENERATOR" "$TEST_ROOT/only-sql" "${kind}recipepack" "$output" >"$TEST_ROOT/generator.log" 2>&1
    [[ ! -e "$output" ]] || fail "Skipping the only Recipe retained stale pack output"
done

mkdir "$TEST_ROOT/bin"
cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
printf 'rad %s\n' "$*" >>"$COMMAND_CALLS"
echo "fixture: stop before accessing a cluster" >&2
exit 1
EOF
cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
printf 'kubectl %s\n' "$*" >>"$COMMAND_CALLS"
exit 1
EOF
chmod +x "$TEST_ROOT/bin/rad" "$TEST_ROOT/bin/kubectl"

for kind in bicep terraform; do
    for consent in unset "" N Y invalid; do
        : >"$COMMAND_CALLS"
        (
            cd "$FIXTURE_ROOT"
            status=0
            with_consent "$consent" env "PATH=$TEST_ROOT/bin:$PATH" bash "$RUNNER" "Data/sqlServerDatabases/recipes/kubernetes/$kind" >"$TEST_ROOT/runner.log" 2>&1 || status=$?
            case "$consent" in
                Y)
                    [[ "$status" == 1 ]] || fail "Opted-in runner did not reach the workspace fixture"
                    grep -Fxq 'rad workspace switch default' "$COMMAND_CALLS" || fail "Opted-in runner still skipped deployment"
                    ;;
                invalid)
                    [[ "$status" != 0 ]] || fail "Runner accepted invalid consent"
                    [[ ! -s "$COMMAND_CALLS" ]] || fail "Invalid consent reached a cluster command"
                    grep -Fq 'Error: RTC_SQLSERVER_ACCEPT_EULA must be' "$TEST_ROOT/runner.log" || fail "Runner omitted the invalid-consent error"
                    ;;
                *)
                    [[ "$status" == 0 ]] || fail "Runner did not skip without consent"
                    [[ ! -s "$COMMAND_CALLS" ]] || fail "Runner accessed a cluster without consent"
                    grep -Fq 'Skipping SQL Server Kubernetes Recipe: no operator EULA consent' "$TEST_ROOT/runner.log" || fail "Runner did not explain the skip"
                    ;;
            esac
        )
    done
done

for recipe in Data/widgets/recipes/kubernetes/bicep Data/sqlServerDatabases/recipes/azure/bicep; do
    : >"$COMMAND_CALLS"
    (
        cd "$FIXTURE_ROOT"
        status=0
        PATH="$TEST_ROOT/bin:$PATH" RTC_SQLSERVER_ACCEPT_EULA=invalid bash "$RUNNER" "$recipe" >"$TEST_ROOT/runner.log" 2>&1 || status=$?
        [[ "$status" == 1 ]] || fail "Unrelated Recipe did not reach the workspace fixture"
        grep -q '^rad workspace switch ' "$COMMAND_CALLS" || fail "Unrelated Recipe was license-gated"
        ! grep -q 'RTC_SQLSERVER_ACCEPT_EULA' "$TEST_ROOT/runner.log" || fail "Unrelated Recipe parsed Kubernetes SQL consent"
    )
done

echo "SQL Server EULA opt-in and skip tests passed (no cluster accessed)"
