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
cp "$REPO_ROOT/.github/scripts/"{select-azure-test-location,lib-azure-postgres-test}.sh "$TEST_ROOT/scripts/"
export CALL_LOG="$TEST_ROOT/calls"
export PROBE_RESULTS="$TEST_ROOT/probe-results"
export RTC_AZURE_SELECTION_FILE="$TEST_ROOT/selection.json"

cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
echo "az $*" >>"$CALL_LOG"
[[ "$2" == "create" && -n "${GROUP_CREATE_FAILS:-}" ]] && exit 1
if [[ "$2" == "delete" ]]; then
    [[ "$*" != *" --no-wait "* ]] || exit 90
    [[ -z "${GROUP_DELETE_SLEEP:-}" ]] || sleep "$GROUP_DELETE_SLEEP"
    [[ -n "${GROUP_DELETE_FAILS:-}" ]] && exit 1
fi
exit 0
EOF
cat >"$TEST_ROOT/scripts/probe-azure-postgres-capacity.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "probe $AZURE_LOCATION $RTC_POSTGRES_TEST_SIZE attempts=$RTC_POSTGRES_PROBE_ATTEMPTS timeout=$RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS" >>"$CALL_LOG"
result="$(head -n 1 "$PROBE_RESULTS")"
sed -i '1d' "$PROBE_RESULTS"
[[ -z "${PROBE_SLEEP:-}" ]] || sleep "$PROBE_SLEEP"
case "$result" in
    0) outcome=available; code="" ;;
    2) outcome=capacity_exhausted; code=SkuNotAvailable ;;
    3) outcome=timeout; code=CreateTimeout ;;
    *) outcome=probe_error; code=AuthorizationFailed ;;
esac
if [[ -z "${NO_RECORD:-}" ]]; then
    jq -n --arg outcome "$outcome" --arg errorCode "$code" \
        '{outcome:$outcome,errorCode:$errorCode}' >"$RTC_POSTGRES_PROBE_RESULT_FILE"
fi
if [[ -n "${BAD_RECORD:-}" ]]; then printf '%s\n' '{}' >"$RTC_POSTGRES_PROBE_RESULT_FILE"; fi
exit "$result"
EOF
chmod +x "$TEST_ROOT/bin/az" "$TEST_ROOT/scripts/"*.sh
fail() { echo "FAIL: $1" >&2; exit 1; }
select_location() {
    AZURE_SUBSCRIPTION_ID="${SELECT_SUBSCRIPTION-}" PATH="$TEST_ROOT/bin:$PATH" \
        "$TEST_ROOT/scripts/select-azure-test-location.sh" probe-rg "$@" 2>"$TEST_ROOT/stderr"
}
reset() {
    : >"$CALL_LOG"
    rm -f "$RTC_AZURE_SELECTION_FILE"
    printf '%s\n' "$@" >"$PROBE_RESULTS"
}
assert_json() { jq -e "$1" "$RTC_AZURE_SELECTION_FILE" >/dev/null || fail "JSON: $1"; }
probe_count() { grep -c '^probe ' "$CALL_LOG" || true; }

reset 0
selection_started="$(date +%s)"
[[ "$(select_location westus3 eastus2)" == westus3 ]] || fail "preferred region"
selection_finished="$(date +%s)"
[[ "$(probe_count)" == 1 ]] || fail "stop at success"
grep -q '^probe westus3 S attempts=1 timeout=900$' "$CALL_LOG" || fail "bounded single probe"
grep -q '^az group delete --name probe-rg' "$CALL_LOG" || fail "group cleanup"
! grep -q -- '--no-wait' "$CALL_LOG" || fail "group deletion must wait for completion"
assert_json '.version == 1 and .status == "selected" and .location == "westus3" and
    .postgres == {size:"S",skuName:"Standard_B1ms",tier:"Burstable"} and
    .attempts[0] == {region:"westus3",size:"S",skuName:"Standard_B1ms",tier:"Burstable",
                     outcome:"available",errorCode:"",durationSeconds:.attempts[0].durationSeconds} and
    (.attempts[0].durationSeconds | type == "number")'
assert_json ".deadlineEpochSeconds >= $((selection_started + 3600)) and
    .deadlineEpochSeconds <= $((selection_finished + 3600))"
reset 0
[[ "$(env -u RTC_AZURE_SELECTION_FILE PATH="$TEST_ROOT/bin:$PATH" \
    "$TEST_ROOT/scripts/select-azure-test-location.sh" probe-rg westus3 2>/dev/null)" == westus3 ]] ||
    fail "legacy caller without a result file"
[[ ! -f "$RTC_AZURE_SELECTION_FILE" ]] || fail "result file must be optional"

reset 2 0
[[ "$(select_location westus3 eastus2)" == eastus2 ]] || fail "second region"
! grep -q -- '--subscription' "$CALL_LOG" || fail "default subscription"
reset 2 2 0
[[ "$(select_location westus3 eastus2 centralus westus2)" == centralus ]] || fail "third region"
reset 2 2 2 0
[[ "$(select_location westus3 eastus2 centralus westus2)" == westus2 ]] || fail "fourth region"

reset 2 2 2 2 2 0
[[ "$(select_location westus3 eastus2 centralus westus2)" == eastus2 ]] || fail "SKU fallback"
expected=$'westus3 S\neastus2 S\ncentralus S\nwestus2 S\nwestus3 M\neastus2 M'
[[ "$(awk '/^probe / {print $2, $3}' "$CALL_LOG")" == "$expected" ]] || fail "size outer, region inner"
assert_json '.postgres == {size:"M",skuName:"Standard_D2ds_v5",tier:"GeneralPurpose"} and
    (.attempts | length) == 6 and .attempts[4].errorCode == "SkuNotAvailable"'

reset 2 2 2 2 2 2 2 2
[[ "$(select_location westus3 eastus2 centralus westus2)" == westus3 ]] || fail "legacy fallback"
[[ "$(probe_count)" == 8 ]] || fail "eight distinct tuples"
assert_json '.status == "capacity_exhausted" and (has("postgres") | not) and (.attempts | length) == 8'
grep -q 'No PostgreSQL tuple was selected' "$TEST_ROOT/stderr" || fail "explicit failure message"

reset 1 0
[[ "$(select_location westus3 eastus2)" == westus3 ]] || fail "other error fallback region"
[[ "$(probe_count)" == 1 ]] || fail "non-capacity error stops selection"
assert_json '.status == "probe_error" and .attempts[0].errorCode == "AuthorizationFailed" and (has("postgres") | not)'
reset 3 0
select_location westus3 >/dev/null
[[ "$(probe_count)" == 1 ]] || fail "timeout must stop selection"
assert_json '.status == "probe_error" and .attempts[0].outcome == "timeout"'

reset 0
[[ "$(RTC_POSTGRES_TEST_SIZES=S select_location centralus)" == centralus ]] || fail "one candidate"
[[ "$(probe_count)" == 1 ]] || fail "one candidate must be verified"
reset 2 0
[[ "$(RTC_POSTGRES_TEST_SIZES=S,M,S RTC_AZURE_TEST_REGIONS=eastus2,eastus2,westus3 select_location ignored)" == westus3 ]] ||
    fail "explicit list precedence/deduplication"
[[ "$(probe_count)" == 2 ]] || fail "remove duplicates"

reset 0
SELECT_SUBSCRIPTION=sub-123 select_location westus3 >/dev/null
[[ "$(grep -c -- '--subscription sub-123' "$CALL_LOG")" == 2 ]] || fail "group subscription"
reset 0
GROUP_CREATE_FAILS=1 select_location westus3 >/dev/null
[[ "$(probe_count)" == 0 ]] || fail "group create failure stops probes"
assert_json '.status == "probe_error" and .attempts == []'
grep -q '^az group delete' "$CALL_LOG" || fail "clean partially created group"
reset 0
if GROUP_DELETE_FAILS=1 select_location westus3 >/dev/null; then fail "group delete failure must fail"; fi
assert_json '.status == "probe_error" and (has("postgres") | not)'
reset 0
if RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS=1 GROUP_DELETE_SLEEP=20 select_location westus3 >/dev/null 2>&1; then
    fail "bounded group deletion timeout must fail"
fi
[[ "$(grep -c '^az group delete' "$CALL_LOG")" == 1 ]] || fail "one timed group deletion"
assert_json '.status == "probe_error" and (has("postgres") | not)'
reset 0
NO_RECORD=1 select_location westus3 >/dev/null
assert_json '.status == "probe_error"'
reset 0
BAD_RECORD=1 select_location westus3 >/dev/null
assert_json '.status == "probe_error"'

reset 0
[[ "$(RTC_POSTGRES_TEST_SIZES=M,S select_location westus3)" == westus3 ]] || fail "configured size order"
grep -q '^probe westus3 M ' "$CALL_LOG" || fail "explicit M preference"

reset 2 0
selection_started="$(date +%s)"
RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=3 PROBE_SLEEP=4 select_location westus3 eastus2 >/dev/null
[[ "$(probe_count)" == 1 ]] || fail "global deadline stops candidates"
grep -qE 'timeout=[1-3]$' "$CALL_LOG" || fail "create capped by remaining time"
assert_json '.status == "deadline_exceeded" and (has("postgres") | not)'
assert_json ".deadlineEpochSeconds >= $((selection_started + 3)) and
    .deadlineEpochSeconds <= $((selection_started + 5))"
reset 0
RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=3 PROBE_SLEEP=4 select_location westus3 >/dev/null
assert_json '.status == "deadline_exceeded" and (has("postgres") | not)'

for setting in RTC_POSTGRES_TEST_SIZES= RTC_POSTGRES_TEST_SIZES=L RTC_POSTGRES_TEST_SIZES=S,,M \
    'RTC_POSTGRES_TEST_SIZES=S,' RTC_POSTGRES_TEST_SIZES='S M' RTC_AZURE_TEST_REGIONS= \
    RTC_AZURE_TEST_REGIONS=WestUS3 RTC_AZURE_TEST_REGIONS=westus3,,eastus2 \
    'RTC_AZURE_TEST_REGIONS=westus3,' $'RTC_AZURE_TEST_REGIONS=westus3\neastus2' \
    RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=0 RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=3601 \
    RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=999999999999999999 \
    RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=bad RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS=0; do
    reset 0
    if env "$setting" PATH="$TEST_ROOT/bin:$PATH" "$TEST_ROOT/scripts/select-azure-test-location.sh" \
        probe-rg westus3 >/dev/null 2>&1; then fail "invalid setting accepted: $setting"; fi
    [[ ! -s "$CALL_LOG" ]] || fail "invalid input must not call Azure: $setting"
done
reset 0
if select_location westus3 eastus2 centralus westus2 northcentralus >/dev/null; then fail "region bound"; fi
if select_location >/dev/null; then fail "missing regions"; fi
if select_location $'westus3\r' >/dev/null; then fail "CR must not be accepted"; fi
[[ ! -s "$CALL_LOG" ]] || fail "invalid regions must not call Azure"
reset 0
if RTC_AZURE_TEST_REGIONS="$(printf 'westus3,%.0s' {1..32})westus3" select_location >/dev/null; then fail "raw region bound"; fi
if RTC_POSTGRES_TEST_SIZES="$(printf 'S,%.0s' {1..32})S" select_location westus3 >/dev/null; then fail "raw size bound"; fi
[[ ! -s "$CALL_LOG" ]] || fail "oversized lists must not call Azure"
echo "Select Azure test location tests passed"
