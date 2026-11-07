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
export GROUP_STATE="$TEST_ROOT/group"
export PROBE_RESULTS="$TEST_ROOT/probe-results"
export RTC_AZURE_SELECTION_FILE="$TEST_ROOT/selection.json"
export RTC_POSTGRES_PROBE_OWNER_TOKEN=0123456789abcdef0123456789abcdef
PROBE_GROUP="rrttest-nightly-123-1-probe-$RTC_POSTGRES_PROBE_OWNER_TOKEN"

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
case "$command" in
    exists)
        if [[ -s "$GROUP_STATE" ]]; then echo true; else echo false; fi
        ;;
    show)
        [[ -s "$GROUP_STATE" ]] || exit 1
        if [[ "$query" == tags.rtcPostgresSelectorOwner ]]; then
            if [[ -n "${GROUP_OWNER_MISMATCH:-}" ]]; then
                echo another-owner
            else
                cut -d'|' -f2 "$GROUP_STATE"
            fi
        fi
        ;;
    create)
        owner=""
        for tag in "${tags[@]}"; do
            [[ "$tag" == rtcPostgresSelectorOwner=* ]] && owner="${tag#*=}"
        done
        printf '%s|%s|%s\n' "$group" "$owner" "$location" >"$GROUP_STATE"
        ;;
    delete)
        [[ -z "${GROUP_DELETE_FAILS:-}" ]] || exit 1
        : >"$GROUP_STATE"
        ;;
    *) exit 1 ;;
esac
EOF

cat >"$TEST_ROOT/scripts/probe-azure-postgres-capacity.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "probe group=$AZURE_RESOURCE_GROUP region=$AZURE_LOCATION size=$RTC_POSTGRES_TEST_SIZE lifecycle=$RTC_POSTGRES_PROBE_GROUP_LIFECYCLE" >>"$CALL_LOG"
result="$(head -n 1 "$PROBE_RESULTS")"
sed -i '1d' "$PROBE_RESULTS"
status="${result%% *}"
code="${result#* }"
case "$status" in
    0) outcome=available; code="" ;;
    2) outcome=capacity_exhausted ;;
    3) outcome=timeout ;;
    4) outcome=unsupported ;;
    5) outcome=restricted ;;
    *) outcome=probe_error ;;
esac
if [[ -z "${MALFORMED_PROBE_RESULT:-}" ]]; then
    jq -n --arg outcome "$outcome" --arg errorCode "$code" \
        '{outcome:$outcome,errorCode:$errorCode}' >"$RTC_POSTGRES_PROBE_RESULT_FILE"
else
    printf '%s\n' '{"outcome":42}' >"$RTC_POSTGRES_PROBE_RESULT_FILE"
fi
exit "$status"
EOF

chmod +x "$TEST_ROOT/bin/az" "$TEST_ROOT/scripts/"*.sh

fail() { echo "FAIL: $1" >&2; exit 1; }
reset() {
    : >"$CALL_LOG"
    : >"$GROUP_STATE"
    rm -f "$RTC_AZURE_SELECTION_FILE"
    printf '%s\n' "$@" >"$PROBE_RESULTS"
}
select_location() {
    PATH="$TEST_ROOT/bin:$PATH" \
        "$TEST_ROOT/scripts/select-azure-test-location.sh" "$PROBE_GROUP" "$@" \
        2>"$TEST_ROOT/stderr"
}
assert_json() {
    local filter="$1"
    shift
    jq -e "$@" "$filter" "$RTC_AZURE_SELECTION_FILE" >/dev/null || fail "JSON: $filter"
}
probe_count() { grep -c '^probe ' "$CALL_LOG" || true; }

reset "0 ignored"
[[ "$(select_location westus3 eastus2)" == westus3 ]] || fail "preferred region"
[[ "$(probe_count)" == 1 ]] || fail "stop after success"
grep -Fq "az group create --name $PROBE_GROUP" "$CALL_LOG" || fail "exact probe group"
grep -Fq "rtcPostgresSelectorOwner=$RTC_POSTGRES_PROBE_OWNER_TOKEN" "$CALL_LOG" ||
    fail "owner tag"
grep -Fq "probe group=$PROBE_GROUP region=westus3 size=S lifecycle=true" "$CALL_LOG" ||
    fail "group lifecycle probe"
grep -Fq "az group delete --name $PROBE_GROUP" "$CALL_LOG" || fail "group cleanup"
[[ ! -s "$GROUP_STATE" ]] || fail "group deletion confirmed"
# shellcheck disable=SC2016 # jq expands $group from --arg.
assert_json '.status == "selected" and .location == "westus3" and
    .probeResourceGroup == $group and
    .postgres == {size:"S",skuName:"Standard_B1ms",tier:"Burstable"} and
    .attempts[0].cleanup == "not_required"' --arg group "$PROBE_GROUP"

reset "5 RegionRestricted" "0 ignored"
[[ "$(select_location westus3 eastus2)" == eastus2 ]] || fail "restriction fallback"
expected=$'westus3 S\neastus2 S'
[[ "$(awk '/^probe / {
    for (i=1;i<=NF;i++) {
        if ($i ~ /^region=/) {sub(/^region=/,"",$i); region=$i}
        if ($i ~ /^size=/) {sub(/^size=/,"",$i); size=$i}
    }
    print region, size
}' "$CALL_LOG")" == "$expected" ]] || fail "candidate order"
assert_json '.attempts[0].outcome == "restricted" and
    .attempts[0].errorCode == "RegionRestricted" and .status == "selected"'

reset "4 UnsupportedSku" "5 RegionRestricted"
RTC_POSTGRES_TEST_SIZES=S select_location westus3 eastus2 >/dev/null
assert_json '.status == "catalog_unavailable" and
    [.attempts[].outcome] == ["unsupported","restricted"] and (has("postgres") | not)'

reset "2 SkuNotAvailable" "2 ServerIsBusy"
RTC_POSTGRES_TEST_SIZES=S select_location westus3 eastus2 >/dev/null
assert_json '.status == "capacity_exhausted" and (.attempts | length) == 2'

reset "4 UnsupportedSku" "4 UnsupportedTier"
RTC_POSTGRES_TEST_SIZES=S select_location westus3 eastus2 >/dev/null
assert_json '.status == "unsupported"'

reset "5 RegionRestricted" "5 RegionRestricted"
RTC_POSTGRES_TEST_SIZES=S select_location westus3 eastus2 >/dev/null
assert_json '.status == "restricted"'

reset "3 CreateTimeout" "0 ignored"
if select_location westus3 eastus2 >/dev/null; then fail "timeout must fail closed"; fi
[[ "$(probe_count)" == 1 ]] || fail "timeout stops allocation"
grep -Fq "probe group=$PROBE_GROUP" "$CALL_LOG" || fail "timeout confined to probe group"
grep -Fq "az group delete --name $PROBE_GROUP" "$CALL_LOG" || fail "timeout group cleanup"
assert_json '.status == "probe_error" and .attempts[0].outcome == "timeout"'

reset "1 AuthorizationFailed" "0 ignored"
if select_location westus3 eastus2 >/dev/null; then fail "operational error must fail"; fi
[[ "$(probe_count)" == 1 ]] || fail "operational error stops allocation"
assert_json '.status == "probe_error" and .attempts[0].errorCode == "AuthorizationFailed"'

reset "0 ignored"
if MALFORMED_PROBE_RESULT=1 select_location westus3 >/dev/null; then
    fail "malformed probe result must fail"
fi
assert_json '.status == "probe_error"'

reset "0 ignored"
if GROUP_DELETE_FAILS=1 select_location westus3 >/dev/null; then
    fail "group cleanup failure must fail"
fi
assert_json '.status == "probe_error" and (has("postgres") | not)'

reset "0 ignored"
if GROUP_OWNER_MISMATCH=1 select_location westus3 >/dev/null; then
    fail "owner mismatch must fail"
fi
! grep -q '^az group delete' "$CALL_LOG" || fail "must not delete foreign group"
[[ -s "$GROUP_STATE" ]] || fail "foreign group preserved"

for setting in RTC_POSTGRES_PROBE_OWNER_TOKEN=bad RTC_POSTGRES_TEST_SIZES=L \
    RTC_AZURE_TEST_REGIONS=WestUS3 RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=0 \
    RTC_POSTGRES_PREFLIGHT_TIMEOUT_SECONDS=3301; do
    reset "0 ignored"
    if env "$setting" PATH="$TEST_ROOT/bin:$PATH" RTC_AZURE_SELECTION_FILE="$RTC_AZURE_SELECTION_FILE" \
        PROBE_RESULTS="$PROBE_RESULTS" CALL_LOG="$CALL_LOG" GROUP_STATE="$GROUP_STATE" \
        "$TEST_ROOT/scripts/select-azure-test-location.sh" "$PROBE_GROUP" westus3 \
        >/dev/null 2>&1; then
        fail "invalid setting accepted: $setting"
    fi
    [[ ! -s "$CALL_LOG" ]] || fail "invalid input called Azure: $setting"
done

echo "Select Azure test location tests passed"
