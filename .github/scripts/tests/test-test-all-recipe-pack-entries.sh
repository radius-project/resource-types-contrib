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

SCRIPTS_COPY="$TEST_ROOT/scripts"
cp -r "$REPO_ROOT/.github/scripts" "$SCRIPTS_COPY"
cp "$TEST_ROOT/bin/test-recipe-pack-entry.sh" "$SCRIPTS_COPY/test-recipe-pack-entry.sh"

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
test-recipe-pack-entry.sh Compute/persistentVolumes azure-ws azure-env
test-recipe-pack-entry.sh Compute/routes azure-ws azure-env"
diff -u <(echo "$expected") "$CALL_LOG" ||
    fail "expected direct-module and repository-owned entries to run with their pack active"
grep -q "1 skipped" <<<"$output" ||
    fail "expected the containerImages exclusion to be reported"
if grep -q 'test-recipe-pack-entry.sh Compute/containerImages' "$CALL_LOG"; then
    fail "the explicitly excluded containerImages entry should not run"
fi

rm "$FIXTURE_ROOT/Messaging/rabbitMQ/test/app.bicep"
: >"$CALL_LOG"
if FAIL_TYPE="" run_driver azure azure-ws azure-env; then
    fail "expected an unapproved missing test app to fail the driver"
fi
grep -q "test-recipe-pack-entry.sh Data/redisCaches" "$CALL_LOG" ||
    fail "expected testing to continue after an unapproved missing test app"
echo "param applicationName string" >"$FIXTURE_ROOT/Messaging/rabbitMQ/test/app.bicep"

: >"$CALL_LOG"
if FAIL_TYPE="Data/redisCaches" run_driver azure azure-ws azure-env; then
    fail "expected a failing entry to fail the driver"
fi
grep -q "test-recipe-pack-entry.sh Messaging/rabbitMQ" "$CALL_LOG" ||
    fail "expected testing to continue after an entry failure"

: >"$CALL_LOG"
run_driver kubernetes kubernetes-ws kubernetes-env >/dev/null ||
    fail "expected the Kubernetes MySQL connection probe to pass"
grep -q "test-recipe-pack-entry.sh Data/mySqlDatabases kubernetes-ws kubernetes-env connection-only" "$CALL_LOG" ||
    fail "expected Kubernetes MySQL to use the connection-only probe"

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
