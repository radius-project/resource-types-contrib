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
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-azure-cleanup-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
export CALL_LOG="$TEST_ROOT/calls" GROUPS_FILE="$TEST_ROOT/groups" VAULTS_FILE="$TEST_ROOT/vaults"

cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
echo "$*" >>"$CALL_LOG"
case "$1 $2" in
    "group list")
        if [[ "${FAIL_GROUP_LIST:-0}" == 1 ]]; then
            echo "ERROR: cannot list groups" >&2
            exit 1
        fi
        cat "$GROUPS_FILE"
        ;;
    "group delete")
        if [[ "$4" == rrttest-current && "${FAIL_CURRENT:-0}" == 1 ]] ||
            [[ "$4" == rrttest-old && "${FAIL_STALE:-0}" == 1 ]]; then
            printf 'ERROR: cannot delete group\nadditional detail\n' >&2
            exit 1
        fi
        ;;
    "keyvault list-deleted")
        if [[ "${FAIL_VAULT_LIST:-0}" == 1 ]]; then
            echo "ERROR: cannot list vaults" >&2
            exit 1
        fi
        cat "$VAULTS_FILE"
        ;;
    "keyvault purge")
        if [[ "${FAIL_PURGE:-0}" == 1 ]]; then
            printf 'ERROR: cannot purge vault\nadditional detail\n' >&2
            exit 1
        fi
        ;;
    *)
        echo "Unexpected Azure CLI call" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/az"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_cleanup() {
    : >"$CALL_LOG"
    PATH="$TEST_ROOT/bin:$PATH" AZURE_RESOURCE_GROUP="${TEST_GROUP-rrttest-current}" \
        AZURE_SUBSCRIPTION_ID=test-subscription \
        bash "$REPO_ROOT/.github/scripts/cleanup-azure-resources.sh"
}

now=$(date +%s)
old=$((now - 48 * 3600))
future=$((now + 48 * 3600))
printf 'rrttest-current\t%s\nrrttest-old\t%s\nrrttest-new\t%s\nrrttest-future\t%s\nrrttest-notag\tNone\nrrttest-invalid\tnot-a-number\n' \
    "$old" "$old" "$now" "$future" >"$GROUPS_FILE"
old_date=$(date -u --date="@$old" +%Y-%m-%dT%H:%M:%SZ)
new_date=$(date -u --date="@$now" +%Y-%m-%dT%H:%M:%SZ)
printf 'old-vault\twestus3\t%s\nnew-vault\twestus3\t%s\ninvalid-vault\twestus3\tNone\n' \
    "$old_date" "$new_date" >"$VAULTS_FILE"

run_cleanup >"$TEST_ROOT/output" 2>&1
grep -Fq 'group delete --name rrttest-current --yes --no-wait --subscription test-subscription' "$CALL_LOG" ||
    fail "current run deletion is missing"
grep -Fq 'group delete --name rrttest-old --yes --no-wait --subscription test-subscription' "$CALL_LOG" ||
    fail "stale group deletion is missing"
[[ $(grep -c '^group delete ' "$CALL_LOG") == 2 ]] ||
    fail "recent, future, or untagged groups must not be deleted"
grep -Fq 'keyvault purge --name old-vault --location westus3 --no-wait --subscription test-subscription' "$CALL_LOG" ||
    fail "old vault purge is missing"
[[ $(grep -c '^keyvault purge ' "$CALL_LOG") == 1 ]] ||
    fail "recent or undated vaults must not be purged"
grep -Fq "starts_with(name, 'rrttest-')" "$CALL_LOG" || fail "group selection must be test-only"
grep -Fq "contains(properties.vaultId, '/resourceGroups/rrttest-')" "$CALL_LOG" ||
    fail "vault selection must be test-only"
grep -Fq 'Completion is not verified.' "$TEST_ROOT/output" ||
    fail "asynchronous cleanup must not claim verified completion"

if FAIL_CURRENT=1 run_cleanup >"$TEST_ROOT/output" 2>&1; then
    fail "a failed current-group delete must still fail cleanup"
fi
grep -q 'group delete --name rrttest-old ' "$CALL_LOG" ||
    fail "current-group failure must not prevent the stale-group sweep"
grep -q '^keyvault purge ' "$CALL_LOG" ||
    fail "current-group failure must not prevent the vault sweep"

FAIL_STALE=1 FAIL_PURGE=1 run_cleanup >"$TEST_ROOT/output" 2>&1 ||
    fail "sweep errors must be best-effort"
grep -q 'Warning: could not delete resource group' "$TEST_ROOT/output" || fail "group failure must be visible"
grep -q 'Warning: could not purge Key Vault' "$TEST_ROOT/output" || fail "purge failure must be visible"
if grep -q 'additional detail' "$TEST_ROOT/output"; then
    fail "sweep errors should print only their first line"
fi

FAIL_GROUP_LIST=1 FAIL_VAULT_LIST=1 run_cleanup >"$TEST_ROOT/output" 2>&1 ||
    fail "list errors must be best-effort"
grep -q 'could not list resource groups' "$TEST_ROOT/output" || fail "group list failure must be visible"
grep -q 'could not list soft-deleted Key Vaults' "$TEST_ROOT/output" || fail "vault list failure must be visible"

AZURE_CLEANUP_SWEEP=false run_cleanup >/dev/null
[[ $(wc -l <"$CALL_LOG") == 1 ]] || fail "disabled sweeps must only delete the current group"
for age in invalid -1 0 3; do
    AZURE_CLEANUP_MAX_AGE_HOURS="$age" run_cleanup >/dev/null 2>&1
    [[ $(wc -l <"$CALL_LOG") == 1 ]] || fail "invalid or unsafe age must skip both sweeps"
done
AZURE_CLEANUP_MAX_AGE_HOURS=08 run_cleanup >/dev/null 2>&1
grep -q '^group list ' "$CALL_LOG" || fail "whole-number ages must use decimal arithmetic"

TEST_GROUP="" run_cleanup >/dev/null
[[ ! -s "$CALL_LOG" ]] || fail "missing group must not issue Azure commands"
echo "Azure cleanup tests passed."
