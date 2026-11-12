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
    sleep "${POSTGRES_SLEEP:-0}"
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

: >"$CALL_LOG"
RTC_ACI_TEST_SCOPE=only run_driver azure azure-ws azure-env >/dev/null ||
    fail "ACI-only pack entries must pass without PostgreSQL preflight"
expected="rad env update azure-env --workspace azure-ws --recipe-packs azure-aci
test-recipe-pack-entry.sh Compute/containers azure-ws azure-env"
diff -u <(echo "$expected") "$CALL_LOG" || fail "ACI-only must deploy only the ACI container entry"

: >"$CALL_LOG"
RTC_ACI_TEST_SCOPE=exclude run_driver azure azure-ws azure-env >/dev/null ||
    fail "non-ACI pack entries must pass"
! grep -q 'test-recipe-pack-entry.sh Compute/containers' "$CALL_LOG" ||
    fail "general Azure tests must not deploy ACI containers"
grep -q 'test-recipe-pack-entry.sh Data/redisCaches' "$CALL_LOG" ||
    fail "non-ACI entries must retain coverage"
if RTC_ACI_TEST_SCOPE=invalid run_driver azure azure-ws azure-env >/dev/null 2>&1; then
    fail "invalid ACI scope must fail"
fi

# Excluding ACI must retain non-container entries from the same pack.
aci_pack="$FIXTURE_ROOT/recipe-packs/azure-aci/azure-aci.bicep"
cp "$aci_pack" "$TEST_ROOT/aci-pack.bicep"
sed "/    recipes: {/a\\
      'Radius.Compute/persistentVolumes': {\\
        kind: 'bicep'\\
        source: 'ghcr.io/radius-project/azure-aci-recipes/persistentvolumes:latest'\\
      }" "$TEST_ROOT/aci-pack.bicep" >"$aci_pack"
: >"$CALL_LOG"
RTC_ACI_TEST_SCOPE=exclude run_driver azure azure-ws azure-env >/dev/null ||
    fail "non-container entries in the ACI pack must pass"
[[ "$(grep -c 'test-recipe-pack-entry.sh Compute/persistentVolumes' "$CALL_LOG")" == 2 ]] ||
    fail "volume recipes in both Azure packs must remain covered"
: >"$CALL_LOG"
RTC_ACI_TEST_SCOPE=only run_driver azure azure-ws azure-env >/dev/null ||
    fail "ACI-only must ignore other entries in its pack"
! grep -q 'test-recipe-pack-entry.sh Compute/persistentVolumes' "$CALL_LOG" ||
    fail "ACI-only must not repeat independent volume tests"
cp "$TEST_ROOT/aci-pack.bicep" "$aci_pack"

# The same resource type backed by Kubernetes must remain outside the ACI slots.
aks_pack="$FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep"
cp "$aks_pack" "$TEST_ROOT/aks-pack.bicep"
sed "/    recipes: {/a\\
      'Radius.Compute/containers': {\\
        kind: 'bicep'\\
        source: 'ghcr.io/radius-project/kube-recipes/containers:latest'\\
      }" "$TEST_ROOT/aks-pack.bicep" >"$aks_pack"
: >"$CALL_LOG"
RTC_ACI_TEST_SCOPE=exclude run_driver azure azure-ws azure-env >/dev/null ||
    fail "Kubernetes-backed containers must remain covered"
[[ "$(grep -c 'test-recipe-pack-entry.sh Compute/containers' "$CALL_LOG")" == 1 ]] ||
    fail "only the Kubernetes-backed container entry must run outside ACI"
cp "$TEST_ROOT/aks-pack.bicep" "$aks_pack"

# OpenAI selection must not remove other entries from the same Azure pack.
mkdir -p "$FIXTURE_ROOT/AI/models/test"
echo "param applicationName string" >"$FIXTURE_ROOT/AI/models/test/app.bicep"
sed "/    recipes: {/a\\
      'Radius.AI/models': {\\
        kind: 'bicep'\\
        source: 'ghcr.io/radius-project/azure-recipes/models:latest'\\
      }" "$TEST_ROOT/aks-pack.bicep" >"$aks_pack"
: >"$CALL_LOG"
RTC_OPENAI_TEST_SCOPE=only RTC_ACI_TEST_SCOPE=exclude run_driver azure azure-ws azure-env >/dev/null ||
    fail "OpenAI-only pack entries must pass without PostgreSQL preflight"
expected="rad env update azure-env --workspace azure-ws --recipe-packs azure-aks
test-recipe-pack-entry.sh AI/models azure-ws azure-env"
diff -u <(echo "$expected") "$CALL_LOG" || fail "OpenAI-only must test only the model entry"
: >"$CALL_LOG"
RTC_OPENAI_TEST_SCOPE=exclude run_driver azure azure-ws azure-env >/dev/null ||
    fail "general Azure pack entries must pass without OpenAI"
! grep -q 'test-recipe-pack-entry.sh AI/models' "$CALL_LOG" ||
    fail "general pack runner must not deploy OpenAI"
grep -q 'test-recipe-pack-entry.sh Data/redisCaches' "$CALL_LOG" ||
    fail "OpenAI exclusion lost other entries in its pack"
: >"$CALL_LOG"
run_driver azure azure-ws azure-env >/dev/null || fail "default scope must retain OpenAI"
grep -q 'test-recipe-pack-entry.sh AI/models' "$CALL_LOG" || fail "default pack scope lost OpenAI"
if RTC_OPENAI_TEST_SCOPE=invalid run_driver azure azure-ws azure-env >/dev/null 2>&1; then
    fail "invalid OpenAI scope must fail pack tests"
fi
if RTC_OPENAI_TEST_SCOPE=only FAIL_TYPE=AI/models run_driver azure azure-ws azure-env >/dev/null 2>&1; then
    fail "OpenAI pack test failures must propagate"
fi
cp "$TEST_ROOT/aks-pack.bicep" "$aks_pack"
if RTC_OPENAI_TEST_SCOPE=only run_driver azure azure-ws azure-env >/dev/null 2>&1; then
    fail "an empty OpenAI pack scope must fail"
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
touch "$FIXTURE_ROOT/Data/postgreSqlDatabases/test/test-kubernetes.sh"
run_driver kubernetes kubernetes-ws kubernetes-env >/dev/null ||
    fail "expected the Kubernetes MySQL connection probe to pass"
grep -q "test-recipe-pack-entry.sh Data/mySqlDatabases kubernetes-ws kubernetes-env connection-only" "$CALL_LOG" ||
    fail "expected Kubernetes MySQL to use the connection-only probe"
grep -q "test-recipe-pack-entry.sh Data/postgreSqlDatabases kubernetes-ws kubernetes-env verify-postgresql-transport" "$CALL_LOG" ||
    fail "expected Kubernetes PostgreSQL to run the transport lifecycle"
if grep -q '^probe-azure-postgres-capacity.sh' "$CALL_LOG"; then
    fail "the Azure PostgreSQL capacity probe must not run for Kubernetes"
fi
rm "$FIXTURE_ROOT/Data/postgreSqlDatabases/test/test-kubernetes.sh"
: >"$CALL_LOG"
run_driver kubernetes kubernetes-ws kubernetes-env >/dev/null ||
    fail "expected legacy pinned PostgreSQL sources to retain the generic test"
grep -q '^test-recipe-pack-entry.sh Data/postgreSqlDatabases kubernetes-ws kubernetes-env$' "$CALL_LOG" ||
    fail "expected no transport mode for pinned sources without a lifecycle"

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

# The workflow's separate PostgreSQL phase can use its full bounded budget without
# preventing the later unrelated-entry phase from starting.
: >"$CALL_LOG"
RTC_AZURE_SELECTION_FILE="$selection" RTC_AZURE_PACK_ENTRY_PHASE=postgres POSTGRES_SLEEP=1 \
    EXPECTED_POSTGRES_SIZE=M run_driver azure azure-ws azure-env >/dev/null ||
    fail "long PostgreSQL phase must complete independently"
grep -q '^test-recipe-pack-entry.sh Data/postgreSqlDatabases' "$CALL_LOG" ||
    fail "PostgreSQL phase must run PostgreSQL"
! grep -q '^test-recipe-pack-entry.sh Data/redisCaches' "$CALL_LOG" ||
    fail "PostgreSQL phase must not consume the unrelated-entry phase"
: >"$CALL_LOG"
RTC_AZURE_SELECTION_FILE="$selection" RTC_AZURE_PACK_ENTRY_PHASE=unrelated \
    EXPECTED_POSTGRES_SIZE=M run_driver azure azure-ws azure-env >/dev/null ||
    fail "unrelated entries must run after the PostgreSQL phase"
grep -q '^test-recipe-pack-entry.sh Compute/routes' "$CALL_LOG" ||
    fail "later unrelated entries must still run"
! grep -q '^test-recipe-pack-entry.sh Data/postgreSqlDatabases' "$CALL_LOG" ||
    fail "unrelated phase must not repeat PostgreSQL"

: >"$CALL_LOG"
if RTC_AZURE_SELECTION_FILE="$selection" RTC_AZURE_PACK_ENTRY_PHASE=postgres \
    POSTGRES_SLEEP=1 FAIL_TYPE=Data/postgreSqlDatabases \
    run_driver azure azure-ws azure-env >/dev/null 2>&1; then
    fail "PostgreSQL failure must fail its phase"
fi
: >"$CALL_LOG"
RTC_AZURE_SELECTION_FILE="$selection" RTC_AZURE_PACK_ENTRY_PHASE=unrelated \
    EXPECTED_POSTGRES_SIZE=M run_driver azure azure-ws azure-env >/dev/null ||
    fail "unrelated entries must run after PostgreSQL failure"
grep -q '^test-recipe-pack-entry.sh Compute/routes' "$CALL_LOG" ||
    fail "later unrelated entries must run after PostgreSQL failure"

if bash "$REPO_ROOT/.github/scripts/report-azure-test-failures.sh" \
    "PostgreSQL entry:failure" "Unrelated entries:success" >/dev/null 2>&1; then
    fail "failed PostgreSQL outcome must fail the overall job"
fi
bash "$REPO_ROOT/.github/scripts/report-azure-test-failures.sh" \
    "PostgreSQL entry:success" "Unrelated entries:success" >/dev/null ||
    fail "successful phases must pass the overall job"

# Compare the full selection, including repeated types from different packs.
cp "$aks_pack" "$TEST_ROOT/budget-aks.bicep"
cp "$aci_pack" "$TEST_ROOT/budget-aci.bicep"
mkdir -p "$FIXTURE_ROOT/AI/models/test" "$FIXTURE_ROOT/Storage/objectStorage/test"
echo "param applicationName string" >"$FIXTURE_ROOT/AI/models/test/app.bicep"
echo "param applicationName string" >"$FIXTURE_ROOT/Storage/objectStorage/test/app.bicep"
sed "/    recipes: {/a\\
      'Radius.AI/models': {\\
        kind: 'bicep'\\
        source: 'ghcr.io/radius-project/azure-recipes/models:latest'\\
      }\\
      'Radius.Storage/objectStorage': {\\
        kind: 'bicep'\\
        source: 'mcr.microsoft.com/bicep/avm/res/storage/storage-account:0.31.0'\\
      }" "$TEST_ROOT/budget-aks.bicep" >"$aks_pack"
sed "/    recipes: {/a\\
      'Radius.Compute/persistentVolumes': {\\
        kind: 'bicep'\\
        source: 'ghcr.io/radius-project/azure-aci-recipes/persistentvolumes:latest'\\
      }" "$TEST_ROOT/budget-aci.bicep" >"$aci_pack"
: >"$CALL_LOG"
RTC_ACI_TEST_SCOPE=exclude RTC_AZURE_SELECTION_FILE="$selection" RTC_AZURE_PACK_ENTRY_PHASE=unrelated \
    run_driver azure azure-ws azure-env >/dev/null || fail "baseline unrelated selection must pass"
grep '^test-recipe-pack-entry.sh ' "$CALL_LOG" | sort >"$TEST_ROOT/expected-budget-entries"
: >"$CALL_LOG"
if RTC_ACI_TEST_SCOPE=exclude RTC_AZURE_SELECTION_FILE="$selection" RTC_AZURE_PACK_ENTRY_PHASE=data-ai \
    FAIL_TYPE=Data/redisCaches run_driver azure azure-ws azure-env >/dev/null 2>&1; then
    fail "data/AI phase must retain deployment failures"
fi
grep -q '^test-recipe-pack-entry.sh AI/models ' "$CALL_LOG" ||
    fail "data/AI phase must retain model coverage after a database failure"
! grep -Eq '^test-recipe-pack-entry.sh (Compute|Messaging|Storage)/' "$CALL_LOG" ||
    fail "data/AI phase must not consume the remaining phase"
RTC_ACI_TEST_SCOPE=exclude RTC_AZURE_SELECTION_FILE="$selection" RTC_AZURE_PACK_ENTRY_PHASE=remaining \
    run_driver azure azure-ws azure-env >/dev/null ||
    fail "remaining entries must run after the data/AI phase fails"
grep -q '^test-recipe-pack-entry.sh Storage/objectStorage ' "$CALL_LOG" ||
    fail "remaining phase must exercise storage"
[[ "$(grep -c '^test-recipe-pack-entry.sh Compute/persistentVolumes ' "$CALL_LOG")" == 2 ]] ||
    fail "remaining phase must retain the volume entry from each pack"
grep '^test-recipe-pack-entry.sh ' "$CALL_LOG" | sort >"$TEST_ROOT/actual-budget-entries"
diff -u "$TEST_ROOT/expected-budget-entries" "$TEST_ROOT/actual-budget-entries" ||
    fail "split phases must run every unrelated entry exactly once with the same arguments"
for phase in data-ai remaining invalid; do
    if RTC_AZURE_PACK_ENTRY_PHASE="$phase" run_driver azure azure-ws azure-env >/dev/null 2>&1; then
        fail "$phase phase must require the Azure selection context"
    fi
done
if RTC_AZURE_SELECTION_FILE="$selection" RTC_AZURE_PACK_ENTRY_PHASE=invalid \
    run_driver azure azure-ws azure-env >/dev/null 2>&1; then
    fail "invalid phase must not omit all entries silently"
fi
cp "$TEST_ROOT/budget-aks.bicep" "$aks_pack"
cp "$TEST_ROOT/budget-aci.bicep" "$aci_pack"

python3 - "$REPO_ROOT" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys
import textwrap

source = (Path(sys.argv[1]) / ".github/workflows/nightly-recipe-pack-tests.yaml").read_text()
job = source.split("  nightly-azure-recipe-pack-tests:", 1)[1].split("\n  cleanup-azure-resources:", 1)[0]
steps = re.split(r"^      - name: ", job, flags=re.M)
step_by_id = {}
for step in steps[1:]:
    match = re.search(r"^        id: (\w+)$", step, re.M)
    if match:
        step_by_id[match[1]] = step
ids = ("azure_data_ai_entries", "azure_remaining_entries")
assert re.search(r"^    timeout-minutes: 330$", job, re.M)
for step_id, phase in zip(ids, ("data-ai", "remaining")):
    step = step_by_id[step_id]
    assert "continue-on-error: true" in step
    assert "timeout-minutes: 60" in step
    assert "        if:" not in step
    assert f"RTC_AZURE_PACK_ENTRY_PHASE: {phase}" in step
    command = textwrap.dedent(step.split("        run: |\n", 1)[1])
    for now in (1000, 9000):
        # Execute each real workflow command with an independent step start.
        mock = f"""
date() {{ echo {now}; }}
make() {{
    [[ "$RTC_AZURE_TEST_STEP_DEADLINE_EPOCH" == {now + 3600} ]] || return 92
    [[ "$*" == 'test-recipe-pack-entries PLATFORM_GROUP=azure WORKSPACE=ws ENVIRONMENT=env' ]] || return 93
    return 17
}}
"""
        result = subprocess.run(["bash", "-c", mock + command],
                                env={**os.environ, "AZURE_WORKSPACE_NAME": "ws",
                                     "AZURE_ENVIRONMENT_NAME": "env"})
        assert result.returncode == 17, (step_id, result.returncode)
    assert f"steps.{step_id}.outcome == 'failure'" in job
report = next(step for step in steps if step.startswith("Report Azure test failures\n"))
command = textwrap.dedent(report.split("        run: |\n", 1)[1])
for outcomes in (("success", "success"), ("failure", "success"), ("success", "failure"), ("skipped", "success")):
    env = {**os.environ, "POSTGRES_OUTCOME": "success", "BICEP_OUTCOME": "success",
           "TERRAFORM_OUTCOME": "success", "PACK_DEPLOY_OUTCOME": "success"}
    for step_id, variable, outcome in zip(ids, ("DATA_AI_ENTRIES_OUTCOME", "REMAINING_ENTRIES_OUTCOME"), outcomes):
        assert f"{variable}: ${{{{ steps.{step_id}.outcome }}}}" in report
        env[variable] = outcome
    result = subprocess.run(["bash", "-c", command], env=env, capture_output=True, text=True,
                            cwd=sys.argv[1])
    assert (result.returncode == 0) == (outcomes == ("success", "success")), outcomes
print("Nightly independent entry budgets and failure reporting passed")
PY

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
