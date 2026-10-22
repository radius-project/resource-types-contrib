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
PROBE="$REPO_ROOT/.github/scripts/probe-azure-postgres-capacity.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-postgres-probe-test-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin"
export CALL_LOG="$TEST_ROOT/calls"
export CREATE_RESULTS="$TEST_ROOT/create-results"

# Each create consumes one line of CREATE_RESULTS: ok, capacity, busy, or other.
cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
echo "az $*" >>"$CALL_LOG"
[[ "$3" == "delete" ]] && exit 0
result="$(head -n 1 "$CREATE_RESULTS")"
sed -i '1d' "$CREATE_RESULTS"
case "$result" in
    ok) exit 0 ;;
    capacity) echo '(SkuNotAvailable) Specified SKU is not supported in this region.' >&2 ;;
    busy) echo '(ServerIsBusy) The server is busy.' >&2 ;;
    *) echo '(AuthorizationFailed) The client does not have authorization.' >&2 ;;
esac
exit 1
EOF
chmod +x "$TEST_ROOT/bin/az"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

run_probe() {
    (
        export PATH="$TEST_ROOT/bin:$PATH"
        export AZURE_RESOURCE_GROUP="${PROBE_RG-rg}"
        export AZURE_LOCATION="${PROBE_LOCATION-westus3}"
        export RTC_POSTGRES_PROBE_WAIT_SECONDS=0
        "$PROBE"
    )
}

reset() {
    : >"$CALL_LOG"
    printf '%s\n' "$@" >"$CREATE_RESULTS"
}

count() {
    grep -c "^az postgres flexible-server $1 " "$CALL_LOG" || true
}

reset ok
output=$(run_probe 2>&1) || fail "expected available capacity to pass"
[[ "$(count create)" == 1 && "$(count delete)" == 1 ]] ||
    fail "expected one create and one delete when capacity is available"
grep -q -- '--sku-name Standard_B1ms' "$CALL_LOG" || fail "expected the Standard_B1ms SKU"
grep -q -- '--tier Burstable' "$CALL_LOG" || fail "expected the Burstable tier"
grep -q -- '--location westus3' "$CALL_LOG" || fail "expected the configured location"
grep -q -- '--no-wait' "$CALL_LOG" || fail "expected the probe server delete not to wait"
password="$(grep -oE -- '--admin-password [^ ]+' "$CALL_LOG" | head -n 1 | cut -d' ' -f2)"
if grep -qF -- "$password" <<<"$output"; then
    fail "the probe must not print the server password"
fi

reset capacity busy ok
run_probe >/dev/null 2>&1 || fail "expected capacity errors to be retried"
[[ "$(count create)" == 3 && "$(count delete)" == 3 ]] ||
    fail "expected three probes and a delete after each"
servers="$(grep -oE -- '--name [^ ]+' "$CALL_LOG" | sort -u | wc -l)"
[[ "$servers" -eq 3 ]] || fail "expected each probe to use a new server name"

reset capacity capacity capacity
status=0
output=$(run_probe 2>&1) || status=$?
[[ "$status" -eq 2 ]] || fail "expected persistent capacity errors to exit 2, got $status"
[[ "$(count create)" == 3 ]] || fail "expected the default limit of three probes"
grep -q "This is an Azure capacity limit, not a recipe failure" <<<"$output" ||
    fail "expected a clear capacity error"

reset other ok
status=0
output=$(run_probe 2>&1) || status=$?
[[ "$status" -eq 1 ]] || fail "expected a non-capacity error to exit 1, got $status"
[[ "$(count create)" == 1 ]] || fail "a non-capacity error must not be retried"
grep -q "AuthorizationFailed" <<<"$output" || fail "expected the original error in the output"

reset ok
if PROBE_RG="" run_probe >/dev/null 2>&1; then
    fail "expected a missing resource group to fail"
fi
[[ "$(count create)" == 0 ]] || fail "no probe should run without a resource group"

echo "PostgreSQL capacity probe tests passed"
