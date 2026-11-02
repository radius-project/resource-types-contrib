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
export GROUP_STATE="$TEST_ROOT/groups"
export GROUP_SHOW_COUNT="$TEST_ROOT/show-count"

cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "az $*" >>"$CALL_LOG"
command="$2"
shift 2
group=""
location=""
query=""
tags=()
while (($#)); do
    case "$1" in
        --name) group="$2"; shift 2 ;;
        --location) location="$2"; shift 2 ;;
        --query) query="$2"; shift 2 ;;
        --tags)
            shift
            while (($#)) && [[ "$1" != --* ]]; do tags+=("$1"); shift; done
            ;;
        *) shift ;;
    esac
done
state_owner() { awk -F'|' -v name="$1" '$1 == name { print $2; exit }' "$GROUP_STATE"; }
state_location() { awk -F'|' -v name="$1" '$1 == name { print $3; exit }' "$GROUP_STATE"; }
case "$command" in
    exists)
        exists_count="$(grep -c '^az group exists' "$CALL_LOG" || true)"
        if [[ -n "${GROUP_EXISTS_CHILD_SLEEP:-}" &&
            ( -z "${GROUP_EXISTS_CHILD_SLEEP_AFTER:-}" || exists_count -ge GROUP_EXISTS_CHILD_SLEEP_AFTER ) ]]; then
            if [[ -n "${GROUP_EXISTS_CHILD_IGNORE_TERM:-}" ]]; then
                (trap '' TERM; exec sleep "$GROUP_EXISTS_CHILD_SLEEP") &
            else
                (sleep "$GROUP_EXISTS_CHILD_SLEEP"; echo false) &
            fi
            wait || true
        fi
        if [[ -n "${GROUP_EXISTS_SLEEP:-}" &&
            ( -z "${GROUP_EXISTS_SLEEP_AFTER:-}" || exists_count -ge GROUP_EXISTS_SLEEP_AFTER ) ]]; then
            exec sleep "$GROUP_EXISTS_SLEEP"
        fi
        if grep -Fq "$group|" "$GROUP_STATE"; then echo true; else echo false; fi
        ;;
    show)
        show_count="$(grep -c '^az group show' "$CALL_LOG" || true)"
        if [[ -n "${GROUP_SHOW_CHILD_SLEEP:-}" &&
            ( -z "${GROUP_SHOW_CHILD_SLEEP_AFTER:-}" || show_count -ge GROUP_SHOW_CHILD_SLEEP_AFTER ) ]]; then
            if [[ -n "${GROUP_SHOW_CHILD_IGNORE_TERM:-}" ]]; then
                (trap '' TERM; exec sleep "$GROUP_SHOW_CHILD_SLEEP") &
            else
                (sleep "$GROUP_SHOW_CHILD_SLEEP"; state_owner "$group") &
            fi
            wait || true
        fi
        if [[ -n "${GROUP_SHOW_SLEEP:-}" &&
            ( -z "${GROUP_SHOW_SLEEP_AFTER:-}" || show_count -ge GROUP_SHOW_SLEEP_AFTER ) ]]; then
            exec sleep "$GROUP_SHOW_SLEEP"
        fi
        if [[ ! -f "$GROUP_STATE" ]] || ! grep -Fq "$group|" "$GROUP_STATE"; then exit 1; fi
        if [[ "$query" == tags.rtcPostgresSelectorOwner ]]; then
            if [[ -n "${GROUP_OWNER_MISMATCH_SECOND_SHOW:-}" ]]; then
                show_count=0
                [[ ! -f "$GROUP_SHOW_COUNT" ]] || show_count="$(cat "$GROUP_SHOW_COUNT")"
                show_count=$((show_count + 1))
                echo "$show_count" >"$GROUP_SHOW_COUNT"
                if ((show_count >= 2)); then echo mismatched-owner; else state_owner "$group"; fi
            else
                state_owner "$group"
            fi
        fi
        ;;
    create)
        owner=""
        for tag in "${tags[@]}"; do
            [[ "$tag" == rtcPostgresSelectorOwner=* ]] && owner="${tag#*=}"
        done
        if [[ -n "${ASSERT_CREATE_LOG:-}" ]] &&
            ! grep -Fq "Creating PostgreSQL selector probe group '$group' with rtcPostgresSelectorOwner=$owner." \
                "$ASSERT_CREATE_LOG"; then
            exit 91
        fi
        if [[ -n "${GROUP_CREATE_FAILS:-}" ]]; then
            if [[ -n "${GROUP_CREATE_PARTIAL:-}" ]]; then
                printf '%s|%s|%s\n' "$group" "$owner" "$location" >>"$GROUP_STATE"
            fi
            [[ -z "${GROUP_CREATE_SLEEP:-}" ]] || exec sleep "$GROUP_CREATE_SLEEP"
            exit 1
        fi
        if [[ -n "${GROUP_CREATE_SLEEP:-}" ]]; then
            if [[ -n "${GROUP_CREATE_PARTIAL:-}" ]]; then
                printf '%s|%s|%s\n' "$group" "$owner" "$location" >>"$GROUP_STATE"
            fi
            if [[ -n "${GROUP_CREATE_IGNORE_TERM:-}" ]]; then
                (trap '' TERM; sleep "$GROUP_CREATE_SLEEP") &
                wait
            fi
            exec sleep "$GROUP_CREATE_SLEEP"
        fi
        if grep -Fq "$group|" "$GROUP_STATE"; then
            [[ "$(state_location "$group")" == "$location" ]] || exit 1
        else
            printf '%s|%s|%s\n' "$group" "$owner" "$location" >>"$GROUP_STATE"
        fi
        ;;
    delete)
        ! grep -Fq ' --no-wait ' "$CALL_LOG" || exit 90
        [[ -z "${GROUP_DELETE_SLEEP:-}" ]] || sleep "$GROUP_DELETE_SLEEP"
        [[ -z "${GROUP_DELETE_FAILS:-}" ]] || exit 1
        [[ -z "${GROUP_DELETE_STUCK:-}" ]] || exit 0
        grep -Fv "$group|" "$GROUP_STATE" >"$GROUP_STATE.next" || true
        mv "$GROUP_STATE.next" "$GROUP_STATE"
        ;;
    *) exit 1 ;;
esac
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
    4) outcome=unsupported; code="${PROBE_ERROR_CODE:-UnsupportedSku}" ;;
    *) outcome=probe_error; code="${PROBE_ERROR_CODE:-AuthorizationFailed}" ;;
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
    : >"$GROUP_STATE"
    rm -f "$GROUP_SHOW_COUNT"
    rm -f "$RTC_AZURE_SELECTION_FILE"
    printf '%s\n' "$@" >"$PROBE_RESULTS"
}
assert_json() { jq -e "$1" "$RTC_AZURE_SELECTION_FILE" >/dev/null || fail "JSON: $1"; }
probe_count() { grep -c '^probe ' "$CALL_LOG" || true; }

reset 0
selection_started="$(date +%s)"
[[ "$(ASSERT_CREATE_LOG="$TEST_ROOT/stderr" select_location westus3 eastus2)" == westus3 ]] ||
    fail "preferred region"
selection_finished="$(date +%s)"
[[ "$(probe_count)" == 1 ]] || fail "stop at success"
grep -q '^probe westus3 S attempts=1 timeout=900$' "$CALL_LOG" || fail "bounded single probe"
grep -Eq '^az group delete --name probe-rg-[a-f0-9]{32}' "$CALL_LOG" || fail "group cleanup"
created_group="$(sed -nE 's/^az group create --name ([^ ]+).*/\1/p' "$CALL_LOG")"
deleted_group="$(sed -nE 's/^az group delete --name ([^ ]+).*/\1/p' "$CALL_LOG")"
[[ "$created_group" =~ ^probe-rg-[a-f0-9]{32}$ ]] || fail "direct caller must get a random 128-bit group name"
[[ "$deleted_group" == "$created_group" ]] || fail "direct caller must delete only its random group"
owner_token="${created_group##*-}"
grep -Fq "Creating PostgreSQL selector probe group '$created_group' with rtcPostgresSelectorOwner=$owner_token." \
    "$TEST_ROOT/stderr" || fail "selector must log the exact group and owner before creation"
grep -Fq "rtcPostgresSelectorOwner=$owner_token" "$CALL_LOG" || fail "random name token must match ownership tag"
[[ ! -s "$GROUP_STATE" ]] || fail "owned group removed after selection"
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
reset 4 0
[[ "$(select_location westus3)" == westus3 ]] || fail "unsupported tuple fallback"
[[ "$(probe_count)" == 2 ]] || fail "unsupported tuple must continue to the next configured size"
assert_json '.status == "selected" and .attempts[0].outcome == "unsupported" and
    .attempts[0].errorCode == "UnsupportedSku" and .attempts[1].outcome == "available"'
reset 4 4
select_location westus3 >/dev/null
[[ "$(probe_count)" == 2 ]] || fail "all unsupported tuples must be checked"
assert_json '.status == "unsupported" and (has("postgres") | not) and
    all(.attempts[]; .outcome == "unsupported")'
reset 4 0
PROBE_ERROR_CODE=RegionRestricted select_location westus3 >/dev/null
[[ "$(probe_count)" == 1 ]] || fail "region restriction must stop further allocation"
assert_json '.status == "probe_error" and .attempts[0].errorCode == "RegionRestricted" and
    (has("postgres") | not)'
reset 4 0
PROBE_ERROR_CODE=AuthorizationFailed select_location westus3 >/dev/null
[[ "$(probe_count)" == 1 ]] || fail "unknown unsupported result must stop selection"
assert_json '.status == "probe_error" and .attempts[0].outcome == "probe_error"'
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
[[ "$(grep -c -- '--subscription sub-123' "$CALL_LOG")" -ge 5 ]] || fail "group subscription"
reset 0
if GROUP_CREATE_FAILS=1 select_location westus3 >/dev/null; then fail "group create failure must fail"; fi
[[ "$(probe_count)" == 0 ]] || fail "group create failure stops probes"
assert_json '.status == "probe_error" and .attempts == []'
! grep -q '^az group delete' "$CALL_LOG" || fail "must not delete group with unproven ownership"
[[ ! -s "$GROUP_STATE" ]] || fail "failed create without a partial group"
reset 0
if GROUP_CREATE_FAILS=1 GROUP_CREATE_PARTIAL=1 select_location westus3 >/dev/null; then
    fail "partial group create failure must fail"
fi
[[ "$(grep -c '^az group delete' "$CALL_LOG")" == 1 ]] || fail "delete proven partial group"
[[ ! -s "$GROUP_STATE" ]] || fail "proven partial group cleanup"
reset 0
printf 'probe-rg||westus3\n' >"$GROUP_STATE"
if select_location westus3 >/dev/null; then fail "existing same-location group must be rejected"; fi
! grep -q '^az group create' "$CALL_LOG" || fail "must not update existing same-location group"
! grep -q '^az group delete' "$CALL_LOG" || fail "must not delete existing same-location group"
grep -Fq 'probe-rg||westus3' "$GROUP_STATE" || fail "same-location group preserved"
reset 0
printf 'probe-rg||eastus2\n' >"$GROUP_STATE"
if select_location westus3 >/dev/null; then fail "existing different-location group must be rejected"; fi
! grep -q '^az group create' "$CALL_LOG" || fail "must not update existing different-location group"
! grep -q '^az group delete' "$CALL_LOG" || fail "must not delete existing different-location group"
grep -Fq 'probe-rg||eastus2' "$GROUP_STATE" || fail "different-location group preserved"
reset 0
slow_read_started="$(date +%s)"
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=1 GROUP_EXISTS_SLEEP=3 \
    select_location westus3 >/dev/null 2>&1; then
    fail "slow existence reads must fail at the selection deadline"
fi
slow_read_elapsed=$(( $(date +%s) - slow_read_started ))
((slow_read_elapsed < 5)) || fail "existence reads must be bounded by remaining selection time"
assert_json '.status == "deadline_exceeded" and (has("postgres") | not)'
[[ "$(grep -c '^az group exists' "$CALL_LOG")" == 1 ]] ||
    fail "deadline expiry on the first read must prevent a second pre-create read"
! grep -q '^az group create' "$CALL_LOG" || fail "deadline expiry must prevent allocation"

reset 0
slow_read_started="$(date +%s)"
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=1 GROUP_EXISTS_CHILD_SLEEP_AFTER=1 \
    GROUP_EXISTS_CHILD_SLEEP=8 select_location westus3 >/dev/null 2>&1; then
    fail "existence read with a child holding stdout must hit the selection deadline"
fi
slow_read_elapsed=$(( $(date +%s) - slow_read_started ))
((slow_read_elapsed < 4)) || fail "deadline must terminate Azure CLI child processes holding stdout"
[[ "$(grep -c '^az group exists' "$CALL_LOG")" == 1 ]] ||
    fail "deadline expiry during child-held read must prevent further Azure calls"
! grep -q '^az group create' "$CALL_LOG" || fail "deadline expiry must prevent allocation"

reset 0
slow_read_started="$(date +%s)"
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=1 GROUP_EXISTS_CHILD_SLEEP_AFTER=1 \
    GROUP_EXISTS_CHILD_IGNORE_TERM=1 GROUP_EXISTS_CHILD_SLEEP=8 \
    select_location westus3 >/dev/null 2>&1; then
    fail "TERM-ignoring existence-read descendants must hit the selection deadline"
fi
slow_read_elapsed=$(( $(date +%s) - slow_read_started ))
((slow_read_elapsed < 4)) || fail "deadline must kill TERM-ignoring Azure CLI descendants"
[[ "$(grep -c '^az group exists' "$CALL_LOG")" == 1 ]] ||
    fail "deadline expiry during TERM-ignoring child-held read must stop Azure calls"

reset 0
cleanup_read_started="$(date +%s)"
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=3 RTC_POSTGRES_CLEANUP_RESERVE_SECONDS=2 \
    PROBE_SLEEP=3 GROUP_EXISTS_SLEEP_AFTER=3 GROUP_EXISTS_SLEEP=8 \
    select_location westus3 >/dev/null 2>&1; then
    fail "slow cleanup existence reads must fail within the cleanup reserve"
fi
cleanup_read_elapsed=$(( $(date +%s) - cleanup_read_started ))
((cleanup_read_elapsed < 7)) || {
    echo "cleanup elapsed: $cleanup_read_elapsed" >&2
    cat "$CALL_LOG" "$TEST_ROOT/stderr" >&2
    fail "cleanup existence read exceeded the shared reserve"
}
[[ "$(grep -c '^az group exists' "$CALL_LOG")" -le 3 ]] ||
    { cat "$CALL_LOG" >&2; cat "$TEST_ROOT/stderr" >&2; fail "expired cleanup reserve must stop before an existence read"; }
! grep -q '^az group delete' "$CALL_LOG" || fail "cleanup must not delete without a remaining reserve"
assert_json '.status == "probe_error" and (has("postgres") | not)'

reset 0
cleanup_read_started="$(date +%s)"
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=4 RTC_POSTGRES_CLEANUP_RESERVE_SECONDS=2 \
    PROBE_SLEEP=1 GROUP_EXISTS_CHILD_SLEEP_AFTER=3 GROUP_EXISTS_CHILD_IGNORE_TERM=1 \
    GROUP_EXISTS_CHILD_SLEEP=8 select_location westus3 >/dev/null 2>&1; then
    fail "TERM-ignoring owned-group cleanup existence reads must be bounded"
fi
cleanup_read_elapsed=$(( $(date +%s) - cleanup_read_started ))
((cleanup_read_elapsed < 8)) || fail "cleanup must kill TERM-ignoring Azure CLI descendants"
[[ "$(grep -c '^az group exists' "$CALL_LOG")" == 3 ]] ||
    fail "owned-group cleanup should stop at the bounded TERM-ignoring existence read"
! grep -q '^az group delete' "$CALL_LOG" || fail "cleanup must not delete before bounded existence read"
assert_json '.status == "probe_error" and (has("postgres") | not)'

reset 0
cleanup_read_started="$(date +%s)"
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=4 RTC_POSTGRES_CLEANUP_RESERVE_SECONDS=2 \
    PROBE_SLEEP=1 GROUP_EXISTS_CHILD_SLEEP_AFTER=3 GROUP_EXISTS_CHILD_SLEEP=8 \
    select_location westus3 >/dev/null 2>&1; then
    fail "owned-group cleanup existence read must be bounded"
fi
cleanup_read_elapsed=$(( $(date +%s) - cleanup_read_started ))
((cleanup_read_elapsed < 8)) || fail "cleanup must terminate Azure CLI children holding stdout"
[[ "$(grep -c '^az group exists' "$CALL_LOG")" == 3 ]] ||
    fail "owned-group cleanup should stop at the bounded existence read"
! grep -q '^az group delete' "$CALL_LOG" || fail "cleanup must not delete before ownership checks"
assert_json '.status == "probe_error" and (has("postgres") | not)'

reset 0
cleanup_read_started="$(date +%s)"
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=4 RTC_POSTGRES_CLEANUP_RESERVE_SECONDS=2 \
    PROBE_SLEEP=1 GROUP_SHOW_CHILD_SLEEP_AFTER=2 GROUP_SHOW_CHILD_IGNORE_TERM=1 \
    GROUP_SHOW_CHILD_SLEEP=8 select_location westus3 >/dev/null 2>&1; then
    fail "TERM-ignoring owned-group cleanup ownership reads must be bounded"
fi
cleanup_read_elapsed=$(( $(date +%s) - cleanup_read_started ))
((cleanup_read_elapsed < 8)) || fail "cleanup ownership read must kill TERM-ignoring Azure CLI descendants"
[[ "$(grep -c '^az group show' "$CALL_LOG")" == 2 ]] ||
    fail "owned-group cleanup should stop at the bounded TERM-ignoring ownership read"
! grep -q '^az group delete' "$CALL_LOG" || fail "cleanup must not delete before bounded ownership read"
assert_json '.status == "probe_error" and (has("postgres") | not)'

reset 0
cleanup_read_started="$(date +%s)"
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=3 RTC_POSTGRES_CLEANUP_RESERVE_SECONDS=2 \
    PROBE_SLEEP=3 GROUP_SHOW_SLEEP_AFTER=2 GROUP_SHOW_SLEEP=8 \
    select_location westus3 >/dev/null 2>&1; then
    fail "slow cleanup ownership reads must fail within the cleanup reserve"
fi
cleanup_read_elapsed=$(( $(date +%s) - cleanup_read_started ))
((cleanup_read_elapsed < 7)) || fail "cleanup ownership read exceeded the shared reserve"
[[ "$(grep -c '^az group show' "$CALL_LOG")" -le 2 ]] ||
    { cat "$CALL_LOG" >&2; cat "$TEST_ROOT/stderr" >&2; fail "expired cleanup reserve must stop before an ownership read"; }
! grep -q '^az group delete' "$CALL_LOG" || fail "cleanup must not delete without verified ownership"
assert_json '.status == "probe_error" and (has("postgres") | not)'

reset 0
cleanup_read_started="$(date +%s)"
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=4 RTC_POSTGRES_CLEANUP_RESERVE_SECONDS=2 \
    PROBE_SLEEP=1 GROUP_SHOW_CHILD_SLEEP_AFTER=2 GROUP_SHOW_CHILD_SLEEP=8 \
    select_location westus3 >/dev/null 2>&1; then
    fail "owned-group cleanup ownership read must be bounded"
fi
cleanup_read_elapsed=$(( $(date +%s) - cleanup_read_started ))
((cleanup_read_elapsed < 8)) || fail "cleanup ownership read must terminate Azure CLI children"
[[ "$(grep -c '^az group show' "$CALL_LOG")" == 2 ]] ||
    fail "owned-group cleanup should stop at the bounded ownership read"
! grep -q '^az group delete' "$CALL_LOG" || fail "cleanup must not delete without verified ownership"
assert_json '.status == "probe_error" and (has("postgres") | not)'

reset 0
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=5 GROUP_CREATE_SLEEP=8 \
    select_location westus3 >/dev/null; then fail "group create timeout must fail"; fi
! grep -q '^az group delete' "$CALL_LOG" || fail "must not delete group after uncertain timeout"
[[ ! -s "$GROUP_STATE" ]] || fail "timeout without partial group"
reset 0
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=5 GROUP_CREATE_PARTIAL=1 GROUP_CREATE_SLEEP=8 \
    select_location westus3 >/dev/null; then fail "partial group create timeout must fail"; fi
[[ "$(grep -c '^az group delete' "$CALL_LOG")" == 1 ]] || {
    cat "$CALL_LOG" "$TEST_ROOT/stderr" >&2
    fail "delete proven timed-out partial group"
}
[[ ! -s "$GROUP_STATE" ]] || fail "timed-out partial group cleanup"

reset 0
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=30 GROUP_CREATE_PARTIAL=1 GROUP_CREATE_SLEEP=10 \
    PATH="$TEST_ROOT/bin:$PATH" timeout --signal=TERM --kill-after=5 1 \
    "$TEST_ROOT/scripts/select-azure-test-location.sh" probe-rg westus3 \
    >"$TEST_ROOT/interrupted.stdout" 2>"$TEST_ROOT/interrupted.stderr"; then
    fail "interrupted partial group creation must fail"
fi
interrupted_group="$(sed -nE 's/^az group create --name ([^ ]+).*/\1/p' "$CALL_LOG")"
interrupted_owner="$(sed -nE 's/.*rtcPostgresSelectorOwner=([a-f0-9]{32}).*/\1/p' "$CALL_LOG")"
[[ "$interrupted_group" =~ ^probe-rg-[a-f0-9]{32}$ && "$interrupted_owner" =~ ^[a-f0-9]{32}$ ]] ||
    fail "interrupted create must record its exact group and ownership tag"
grep -Fq "$interrupted_group" "$TEST_ROOT/interrupted.stderr" ||
    fail "interrupted create recovery must report the exact group"
grep -Fq "rtcPostgresSelectorOwner=$interrupted_owner" "$TEST_ROOT/interrupted.stderr" ||
    fail "interrupted create recovery must report its expected ownership tag"
if ! grep -Fq "az group delete --name $interrupted_group" "$CALL_LOG"; then
    cat "$CALL_LOG" >&2
    cat "$TEST_ROOT/interrupted.stderr" >&2
    fail "matching partial group ownership must allow safe cleanup"
fi
[[ ! -s "$GROUP_STATE" ]] || fail "interrupted owned group must be removed"
assert_json '.status == "probe_error" and (has("postgres") | not)'

reset 0
interrupted_started="$(date +%s)"
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=30 GROUP_CREATE_PARTIAL=1 \
    GROUP_CREATE_IGNORE_TERM=1 GROUP_CREATE_SLEEP=30 \
    PATH="$TEST_ROOT/bin:$PATH" timeout --signal=TERM --kill-after=5 1 \
    "$TEST_ROOT/scripts/select-azure-test-location.sh" probe-rg westus3 \
    >"$TEST_ROOT/interrupted-child.stdout" 2>"$TEST_ROOT/interrupted-child.stderr"; then
    fail "TERM-ignoring Azure child must interrupt creation"
fi
interrupted_elapsed=$(( $(date +%s) - interrupted_started ))
((interrupted_elapsed < 5)) || fail "signal handling must bound teardown of a TERM-ignoring Azure child"
interrupted_child_group="$(sed -nE 's/^az group create --name ([^ ]+).*/\1/p' "$CALL_LOG")"
[[ -n "$interrupted_child_group" ]] || fail "interrupted create must have a recovery target"
grep -Fq "$interrupted_child_group" "$TEST_ROOT/interrupted-child.stderr" ||
    fail "interrupted TERM-ignoring create must report its exact group"
[[ ! -s "$GROUP_STATE" ]] || fail "owned partial group must be cleaned after bounded signal teardown"

reset 0
if RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=30 GROUP_CREATE_SLEEP=10 \
    PATH="$TEST_ROOT/bin:$PATH" timeout --signal=TERM --kill-after=5 1 \
    "$TEST_ROOT/scripts/select-azure-test-location.sh" probe-rg westus3 \
    >"$TEST_ROOT/uncertain.stdout" 2>"$TEST_ROOT/uncertain.stderr"; then
    fail "interrupted uncertain group creation must fail"
fi
uncertain_group="$(sed -nE 's/^az group create --name ([^ ]+).*/\1/p' "$CALL_LOG")"
uncertain_owner="$(sed -nE 's/.*rtcPostgresSelectorOwner=([a-f0-9]{32}).*/\1/p' "$CALL_LOG")"
grep -Fq "$uncertain_group" "$TEST_ROOT/uncertain.stderr" ||
    fail "uncertain create recovery must report the exact group"
grep -Fq "rtcPostgresSelectorOwner=$uncertain_owner" "$TEST_ROOT/uncertain.stderr" ||
    fail "uncertain create recovery must report its expected ownership tag"
grep -Fq "does not rule out a late create" "$TEST_ROOT/uncertain.stderr" ||
    fail "uncertain creation must warn that absence may be temporary"
! grep -q '^az group delete' "$CALL_LOG" || fail "unverified interrupted group must not be deleted"
[[ ! -s "$GROUP_STATE" ]] || fail "uncertain create fixture must not create a group"
assert_json '.status == "probe_error" and (has("postgres") | not)'

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
if GROUP_DELETE_STUCK=1 select_location westus3 >/dev/null 2>&1; then
    fail "unconfirmed group deletion must fail"
fi
assert_json '.status == "probe_error" and (has("postgres") | not)'
grep -q '^az group exists' "$CALL_LOG" || fail "confirm resource group deletion"
reset 0
if GROUP_OWNER_MISMATCH_SECOND_SHOW=1 select_location westus3 >/dev/null 2>&1; then
    fail "cleanup must fail when ownership changes after creation"
fi
! grep -q '^az group delete' "$CALL_LOG" || fail "must not delete a group with a mismatched ownership tag"
[[ -s "$GROUP_STATE" ]] || fail "mismatched-owner group must remain untouched"
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
    RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=bad RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS=0 \
    RTC_POSTGRES_CLEANUP_RESERVE_SECONDS=0 RTC_POSTGRES_CLEANUP_RESERVE_SECONDS=901; do
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
