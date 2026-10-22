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
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-select-location-test-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/scripts"
cp "$REPO_ROOT/.github/scripts/select-azure-test-location.sh" "$TEST_ROOT/scripts/"
export CALL_LOG="$TEST_ROOT/calls"
export PROBE_RESULTS="$TEST_ROOT/probe-results"

cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
echo "az $*" >>"$CALL_LOG"
[[ "$2" == "create" && -n "${GROUP_CREATE_FAILS:-}" ]] && exit 1
exit 0
EOF

# Each probe consumes one exit code from PROBE_RESULTS.
cat >"$TEST_ROOT/scripts/probe-azure-postgres-capacity.sh" <<'EOF'
#!/bin/bash
echo "probe $AZURE_RESOURCE_GROUP $AZURE_LOCATION attempts=$RTC_POSTGRES_PROBE_ATTEMPTS" >>"$CALL_LOG"
result="$(head -n 1 "$PROBE_RESULTS")"
sed -i '1d' "$PROBE_RESULTS"
exit "$result"
EOF
chmod +x "$TEST_ROOT/bin/az" "$TEST_ROOT/scripts/"*.sh

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

select_location() {
    PATH="$TEST_ROOT/bin:$PATH" "$TEST_ROOT/scripts/select-azure-test-location.sh" probe-rg "$@" 2>/dev/null
}

reset() {
    : >"$CALL_LOG"
    printf '%s\n' "$@" >"$PROBE_RESULTS"
}

reset 0
[[ "$(select_location westus3 eastus2)" == "westus3" ]] || fail "expected the first region with capacity"
grep -q '^probe probe-rg westus3 attempts=1$' "$CALL_LOG" || fail "expected one probe in westus3"
! grep -q 'eastus2' <(grep '^probe' "$CALL_LOG") || fail "expected no probe after a region is selected"
grep -q '^az group delete --name probe-rg' "$CALL_LOG" || fail "expected the probe group to be deleted"

reset 2 0
[[ "$(select_location westus3 eastus2)" == "eastus2" ]] || fail "expected the fallback region"
[[ "$(grep -c '^probe' "$CALL_LOG")" == 2 ]] || fail "expected a probe in each region"

reset 2 2
[[ "$(select_location westus3 eastus2)" == "westus3" ]] || fail "expected the first region when none has capacity"
grep -q '^az group delete --name probe-rg' "$CALL_LOG" || fail "expected the probe group to be deleted"

reset 1 0
[[ "$(select_location westus3 eastus2)" == "westus3" ]] || fail "expected the first region after a non-capacity error"
[[ "$(grep -c '^probe' "$CALL_LOG")" == 1 ]] || fail "a non-capacity error must stop probing"

reset 0
[[ "$(select_location centralus)" == "centralus" ]] || fail "expected the only candidate"
[[ ! -s "$CALL_LOG" ]] || fail "one candidate must not create probe resources"

reset 0
[[ "$(GROUP_CREATE_FAILS=1 select_location westus3 eastus2)" == "westus3" ]] ||
    fail "expected the first region when the probe group cannot be created"
! grep -q '^probe' "$CALL_LOG" || fail "no probe should run without a probe group"

if PATH="$TEST_ROOT/bin:$PATH" "$TEST_ROOT/scripts/select-azure-test-location.sh" probe-rg >/dev/null 2>&1; then
    fail "expected missing candidates to fail"
fi

echo "Select Azure test location tests passed"
