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

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-test-all-pack-entries-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repo"
mkdir -p \
    "$FIXTURE_ROOT/recipe-packs/azure-aks" \
    "$FIXTURE_ROOT/recipe-packs/azure-aci" \
    "$FIXTURE_ROOT/recipe-packs/kubernetes" \
    "$FIXTURE_ROOT/Data/redisCaches/test" \
    "$FIXTURE_ROOT/Data/mySqlDatabases/test" \
    "$FIXTURE_ROOT/Data/postgreSqlDatabases/test" \
    "$FIXTURE_ROOT/Messaging/rabbitMQ/test" \
    "$FIXTURE_ROOT/Compute/containers/test" \
    "$FIXTURE_ROOT/Compute/persistentVolumes/test" \
    "$FIXTURE_ROOT/Compute/routes/test" \
    "$FIXTURE_ROOT/Compute/containerImages/test" \
    "$TEST_ROOT/bin"

cat >"$FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep" <<'EOF'
resource pack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aks'
  properties: {
    recipes: {
      'Radius.Data/redisCaches': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/cache/redis-enterprise:0.5.1'
      }
      'Radius.Messaging/rabbitMQ': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/rabbitmq:latest'
      }
      'Radius.Data/mySqlDatabases': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/db-for-my-sql/flexible-server:0.10.3'
        parameters: {
          configurations: [
            {
              name: 'require_secure_transport'
              value: '{{context.resource.properties.tls == "optional" ? "OFF" : "ON"}}'
            }
          ]
        }
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/db-for-postgre-sql/flexible-server:0.15.2'
        parameters: {
          skuName: '{{context.resource.properties.size == "S" ? "Standard_B1ms" : "Standard_D2ds_v5"}}'
          tier: '{{context.resource.properties.size == "S" ? "Burstable" : "GeneralPurpose"}}'
          version: '16'
          availabilityZone: -1
          highAvailability: 'Disabled'
          geoRedundantBackup: 'Disabled'
          storageSizeGB: 32
          publicNetworkAccess: 'Enabled'
          activeDirectoryAuth: 'Enabled'
          passwordAuth: 'Enabled'
        }
      }
      'Radius.Compute/persistentVolumes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/persistentvolumes:latest'
      }
      'Radius.Compute/routes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/routes:latest'
      }
      'Radius.Compute/containerImages': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containerimages:latest'
      }
    }
  }
}
EOF

cat >"$FIXTURE_ROOT/recipe-packs/kubernetes/default.bicep" <<'EOF'
resource pack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'default'
  properties: {
    recipes: {
      'Radius.Data/mySqlDatabases': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/mysqldatabases:latest'
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/postgresqldatabases:latest'
      }
    }
  }
}
EOF

cat >"$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep" <<'EOF'
resource pack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aci'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/azure-aci-recipes/containers:latest'
      }
    }
  }
}
EOF

for test_file in \
    "$FIXTURE_ROOT/Data/redisCaches/test/app.bicep" \
    "$FIXTURE_ROOT/Data/mySqlDatabases/test/app.bicep" \
    "$FIXTURE_ROOT/Data/postgreSqlDatabases/test/app.bicep" \
    "$FIXTURE_ROOT/Messaging/rabbitMQ/test/app.bicep" \
    "$FIXTURE_ROOT/Compute/containers/test/app.bicep" \
    "$FIXTURE_ROOT/Compute/persistentVolumes/test/app.bicep" \
    "$FIXTURE_ROOT/Compute/routes/test/app.bicep" \
    "$FIXTURE_ROOT/Compute/containerImages/test/app.bicep"; do
    echo "param applicationName string" >"$test_file"
done

export CALL_LOG="$TEST_ROOT/calls"
export FAIL_TYPE=""
: >"$CALL_LOG"

cat >"$TEST_ROOT/bin/test-recipe-pack-entry.sh" <<'EOF'
#!/bin/bash
echo "test-recipe-pack-entry.sh $*" >>"$CALL_LOG"
if [[ "$1" == Data/postgreSqlDatabases && "${RTC_TEST_PLATFORM:-}" == azure ]]; then
    [[ "${RTC_POSTGRES_TEST_SIZE:-}" == "${EXPECTED_POSTGRES_SIZE:-S}" ]] || exit 96
    [[ "${RTC_POSTGRES_TEST_DEADLINE_EPOCH:-}" =~ ^[0-9]+$ ]] || exit 95
fi
case "$2" in
    azure-ws) [[ "${RTC_TEST_PLATFORM:-}" == azure ]] || exit 97 ;;
    kubernetes-ws) [[ "${RTC_TEST_PLATFORM:-}" == kubernetes ]] || exit 98 ;;
esac
[[ "$1" == "$FAIL_TYPE" ]] && exit 1
exit 0
EOF
chmod +x "$TEST_ROOT/bin/test-recipe-pack-entry.sh"

cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
echo "rad $*" >>"$CALL_LOG"
exit "${ACTIVATE_EXIT_CODE:-0}"
EOF
chmod +x "$TEST_ROOT/bin/rad"

cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
[[ "$*" == "group show "* ]] || exit 1
echo westus3
EOF
chmod +x "$TEST_ROOT/bin/az"
export AZURE_RESOURCE_GROUP=fixture-rg

SCRIPTS_COPY="$TEST_ROOT/scripts"
cp -r "$REPO_ROOT/.github/scripts" "$SCRIPTS_COPY"
cp "$TEST_ROOT/bin/test-recipe-pack-entry.sh" "$SCRIPTS_COPY/test-recipe-pack-entry.sh"
cat >"$SCRIPTS_COPY/probe-azure-postgres-capacity.sh" <<'EOF'
#!/bin/bash
echo "probe-azure-postgres-capacity.sh" >>"$CALL_LOG"
[[ "${AZURE_LOCATION:-}" == westus3 && "${RTC_POSTGRES_TEST_SIZE:-}" == S &&
   "${RTC_POSTGRES_PROBE_ATTEMPTS:-}" == 1 && "${RTC_POSTGRES_PROBE_WAIT_SECONDS:-}" == 0 ]] || exit 94
exit "${PROBE_EXIT_CODE:-0}"
EOF
chmod +x "$SCRIPTS_COPY/probe-azure-postgres-capacity.sh"

run_driver() {
    (
        export RTC_REPO_ROOT="$FIXTURE_ROOT"
        export PATH="$TEST_ROOT/bin:$PATH"
        unset RTC_LIB_NAMESPACES_SOURCED RTC_LIB_RECIPE_PACKS_SOURCED
        cd "$FIXTURE_ROOT"
        "$SCRIPTS_COPY/test-all-recipe-pack-entries.sh" "$@"
    )
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

: >"$CALL_LOG"
output=$(FAIL_TYPE="" run_driver azure azure-ws azure-env) ||
    fail "expected all runnable pack entries to pass"
expected="rad env update azure-env --workspace azure-ws --recipe-packs azure-aci
test-recipe-pack-entry.sh Compute/containers azure-ws azure-env
rad env update azure-env --workspace azure-ws --recipe-packs azure-aks
test-recipe-pack-entry.sh Data/redisCaches azure-ws azure-env
test-recipe-pack-entry.sh Messaging/rabbitMQ azure-ws azure-env
test-recipe-pack-entry.sh Data/mySqlDatabases azure-ws azure-env verify-transport
probe-azure-postgres-capacity.sh
test-recipe-pack-entry.sh Data/postgreSqlDatabases azure-ws azure-env
test-recipe-pack-entry.sh Compute/persistentVolumes azure-ws azure-env
test-recipe-pack-entry.sh Compute/routes azure-ws azure-env"
diff -u <(echo "$expected") "$CALL_LOG" ||
    fail "expected direct-module and repository-owned entries to run with their pack active"
grep -q "7 tested, 1 skipped, 0 failed" <<<"$output" ||
    fail "expected seven runnable entries and only the containerImages exclusion"
if grep -q 'test-recipe-pack-entry.sh Compute/containerImages' "$CALL_LOG"; then
    fail "the explicitly excluded containerImages entry should not run"
fi

rm "$FIXTURE_ROOT/Messaging/rabbitMQ/test/app.bicep"
: >"$CALL_LOG"
if output=$(FAIL_TYPE="" run_driver azure azure-ws azure-env 2>&1); then
    fail "expected an unapproved missing test app to fail the driver"
fi
grep -q "Messaging/rabbitMQ from pack 'azure-aks' has no test/app.bicep" <<<"$output" ||
    fail "expected the missing rabbitMQ test application to cause the failure"
grep -q "test-recipe-pack-entry.sh Data/mySqlDatabases" "$CALL_LOG" ||
    fail "expected testing to continue after an unapproved missing test app"
echo "param applicationName string" >"$FIXTURE_ROOT/Messaging/rabbitMQ/test/app.bicep"

: >"$CALL_LOG"
if output=$(FAIL_TYPE="Data/redisCaches" run_driver azure azure-ws azure-env 2>&1); then
    fail "expected a failing entry to fail the driver"
fi
grep -q "test-recipe-pack-entry.sh Messaging/rabbitMQ" "$CALL_LOG" ||
    fail "expected testing to continue after an entry failure"
grep -q "Data/redisCaches (from pack 'azure-aks')" <<<"$output" ||
    fail "expected the outer loop to record the failed entry"

: >"$CALL_LOG"
run_driver kubernetes kubernetes-ws kubernetes-env >/dev/null ||
    fail "expected the Kubernetes MySQL connection probe to pass"
grep -q "test-recipe-pack-entry.sh Data/mySqlDatabases kubernetes-ws kubernetes-env connection-only" "$CALL_LOG" ||
    fail "expected Kubernetes MySQL to use the connection-only probe"
if grep -q '^probe-azure-postgres-capacity.sh' "$CALL_LOG"; then
    fail "the Azure PostgreSQL capacity probe must not run for Kubernetes"
fi

: >"$CALL_LOG"
if output=$(PROBE_EXIT_CODE=1 run_driver azure azure-ws azure-env 2>&1); then
    fail "expected a failed capacity probe to fail the driver"
fi
grep -q "Data/postgreSqlDatabases (from pack 'azure-aks'): preflight check failed" <<<"$output" ||
    fail "expected the capacity probe failure to be reported for PostgreSQL"
if grep -q '^test-recipe-pack-entry.sh Data/postgreSqlDatabases' "$CALL_LOG"; then
    fail "PostgreSQL must not deploy after a failed capacity probe"
fi
grep -q '^test-recipe-pack-entry.sh Compute/persistentVolumes' "$CALL_LOG" ||
    fail "expected testing to continue after a failed capacity probe"

selection="$TEST_ROOT/selection.json"
jq -n --argjson deadline "$(( $(date +%s) + 600 ))" \
    '{version:1,status:"selected",location:"westus3",deadlineEpochSeconds:$deadline,
      postgres:{size:"M",skuName:"Standard_D2ds_v5",tier:"GeneralPurpose"}}' >"$selection"
: >"$CALL_LOG"
RTC_AZURE_SELECTION_FILE="$selection" EXPECTED_POSTGRES_SIZE=M run_driver azure azure-ws azure-env >/dev/null ||
    fail "selected M must reach the entry runner"
if grep -q '^probe-' "$CALL_LOG"; then fail "selected tuples must not be probed twice"; fi
expected="rad env update azure-env --workspace azure-ws --recipe-packs azure-aks
test-recipe-pack-entry.sh Data/postgreSqlDatabases azure-ws azure-env
test-recipe-pack-entry.sh Data/redisCaches azure-ws azure-env
test-recipe-pack-entry.sh Messaging/rabbitMQ azure-ws azure-env
test-recipe-pack-entry.sh Data/mySqlDatabases azure-ws azure-env verify-transport
test-recipe-pack-entry.sh Compute/persistentVolumes azure-ws azure-env
test-recipe-pack-entry.sh Compute/routes azure-ws azure-env
rad env update azure-env --workspace azure-ws --recipe-packs azure-aci
test-recipe-pack-entry.sh Compute/containers azure-ws azure-env"
diff -u <(echo "$expected") "$CALL_LOG" ||
    fail "selected PostgreSQL must run before unrelated entries, without dropping any"

for state in missing malformed capacity_exhausted probe_error deadline_exceeded invalid_size invalid_tuple wrong_region expired invalid_deadline; do
    case "$state" in
        missing) rm -f "$selection" ;;
        malformed) echo '{' >"$selection" ;;
        invalid_size) echo '{"version":1,"status":"selected","location":"westus3","postgres":{"size":"L"}}' >"$selection" ;;
        invalid_tuple) echo '{"version":1,"status":"selected","location":"westus3","postgres":{"size":"S","skuName":"Other","tier":"Burstable"}}' >"$selection" ;;
        wrong_region) echo '{"version":1,"status":"selected","location":"eastus2","postgres":{"size":"S"}}' >"$selection" ;;
        expired|invalid_deadline)
            deadline=1
            [[ "$state" != invalid_deadline ]] || deadline='"bad"'
            echo "{\"version\":1,\"status\":\"selected\",\"location\":\"westus3\",\"deadlineEpochSeconds\":$deadline,\"postgres\":{\"size\":\"S\",\"skuName\":\"Standard_B1ms\",\"tier\":\"Burstable\"}}" >"$selection" ;;
        *) printf '{"version":1,"status":"%s"}\n' "$state" >"$selection" ;;
    esac
    : >"$CALL_LOG"
    if output=$(RTC_AZURE_SELECTION_FILE="$selection" run_driver azure azure-ws azure-env 2>&1); then
        fail "$state selection must fail PostgreSQL"
    fi
    grep -qi 'PostgreSQL.*selection' <<<"$output" || fail "selection failure must be clear"
    if grep -q '^test-recipe-pack-entry.sh Data/postgreSqlDatabases' "$CALL_LOG"; then
        fail "$state selection must block PostgreSQL deployment"
    fi
    grep -q '^test-recipe-pack-entry.sh Compute/routes' "$CALL_LOG" || fail "later entries must still run"
done

: >"$CALL_LOG"
RTC_AZURE_SELECTION_FILE="$selection" run_driver kubernetes kubernetes-ws kubernetes-env >/dev/null ||
    fail "Kubernetes must ignore Azure selection state"
for code in 2 3; do
    : >"$CALL_LOG"
    if PROBE_EXIT_CODE="$code" run_driver azure azure-ws azure-env >/dev/null 2>&1; then
        fail "probe capacity exhaustion or timeout must fail"
    fi
    grep -q '^test-recipe-pack-entry.sh Compute/routes' "$CALL_LOG" || fail "later entries must run after probe failure"
done

pack="$FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep"
cp "$pack" "$TEST_ROOT/original-pack.bicep"
sed 's/Standard_B1ms/Standard_B2ms/g' "$TEST_ROOT/original-pack.bicep" >"$pack"
: >"$CALL_LOG"
if output=$(run_driver azure azure-ws azure-env 2>&1); then fail "pack mapping drift must fail"; fi
grep -q 'differs from the pack SKU' <<<"$output" || fail "mapping error must identify pack drift"
if grep -q '^test-recipe-pack-entry.sh Data/postgreSqlDatabases' "$CALL_LOG"; then
    fail "mapping drift must block PostgreSQL"
fi
cp "$TEST_ROOT/original-pack.bicep" "$pack"

: >"$CALL_LOG"
if ACTIVATE_EXIT_CODE=1 run_driver azure azure-ws azure-env; then
    fail "expected pack activation failure to fail the driver"
fi
if grep -q '^test-recipe-pack-entry.sh' "$CALL_LOG"; then
    fail "no entry tests should run after activation fails"
fi

rm -f "$FIXTURE_ROOT/Compute/containers/test/app.bicep"
: >"$CALL_LOG"
if output=$(run_driver azure azure-ws azure-env 2>&1); then
    fail "expected a pack with no runnable entries to fail"
fi
grep -q "Recipe Pack 'azure-aci' has no entries with test applications" <<<"$output" ||
    fail "expected the empty azure-aci pack rule to cause the failure"

echo "Test all Recipe Pack entries tests passed"
