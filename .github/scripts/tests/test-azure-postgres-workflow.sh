#!/bin/bash
# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="$root/.github/scripts/azure-postgres-workflow.sh"
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
unset RTC_AZURE_TEST_REGIONS AZURE_LOCATION AZURE_FALLBACK_LOCATION
[[ "$(bash "$script" regions)" == westus3,centralus,northcentralus,southcentralus ]] || fail defaults
[[ "$(AZURE_LOCATION=eastus AZURE_FALLBACK_LOCATION=northeurope bash "$script" regions)" == \
    eastus,northeurope,westus3,centralus ]] || fail "distinct legacy settings and automatic fill"
[[ "$(AZURE_LOCATION=centralus AZURE_FALLBACK_LOCATION=centralus bash "$script" regions)" == \
    centralus,westus3,northcentralus,southcentralus ]] || fail "stable deduplication and automatic fill"
[[ "$(RTC_AZURE_TEST_REGIONS=westus2,westus2,eastus2 AZURE_LOCATION=bad bash "$script" regions)" == \
    westus2,eastus2 ]] || fail "override precedence"
[[ "$(RTC_AZURE_TEST_REGIONS=westus3,centralus,northcentralus,southcentralus bash "$script" regions)" == \
    westus3,centralus,northcentralus,southcentralus ]] || fail "four-region override"
[[ "$(RTC_AZURE_TEST_REGIONS=centralus bash "$script" regions)" == centralus ]] || fail "single region"
for list in '' Westus3 'eastus2,' 'eastus2,,centralus' 'a,b,c,d,e' $'eastus2\r' $'eastus2\nwestus2'; do
    if RTC_AZURE_TEST_REGIONS="$list" bash "$script" regions >/dev/null 2>&1; then fail "invalid list"; fi
done
if RTC_AZURE_TEST_REGIONS="$(printf 'eastus2,%.0s' {1..32})eastus2" \
    bash "$script" regions >/dev/null 2>&1; then fail "raw list bound"; fi

selector_scripts="$temp/selector-scripts"
mkdir "$selector_scripts"
cp "$script" "$selector_scripts/azure-postgres-workflow.sh"
export SIZE_LOG="$temp/selector-sizes"
cat >"$selector_scripts/select-azure-test-location.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$RTC_POSTGRES_TEST_SIZES" >"$SIZE_LOG"
printf '%s\n' "${RTC_AZURE_TEST_REGIONS%%,*}"
jq -n --arg location "${RTC_AZURE_TEST_REGIONS%%,*}" \
    '{version:1,status:"selected",location:$location,deadlineEpochSeconds:123456,
      postgres:{size:"S",skuName:"Standard_B1ms",tier:"Burstable"},
      attempts:[{region:$location,size:"S",skuName:"Standard_B1ms",tier:"Burstable",
        outcome:"selected",errorCode:"",durationSeconds:1}]}' >"$RTC_AZURE_SELECTION_FILE"
exit "${FAKE_SELECTOR_STATUS:-23}"
EOF
chmod +x "$selector_scripts/select-azure-test-location.sh"
failed_selection="$temp/failed-selection.json"
failed_env="$temp/failed-selection.env"
if output=$(RTC_AZURE_TEST_REGIONS=centralus,westus2 RTC_AZURE_SELECTION_FILE="$failed_selection" \
    GITHUB_ENV="$failed_env" bash "$selector_scripts/azure-postgres-workflow.sh" \
    select-context fixture-probe 2>&1); then
    fail "a nonzero selector must remain a workflow failure"
fi
jq -e '.version == 1 and .status == "probe_error" and .location == "centralus" and
    .deadlineEpochSeconds == 123456 and (has("postgres") | not) and
    .attempts[0].region == "centralus"' "$failed_selection" >/dev/null ||
    fail "nonzero selector must preserve diagnostics but fail closed"
grep -Fxq 'AZURE_LOCATION=centralus' "$failed_env" ||
    fail "nonzero selector must export its validated fallback region"
grep -q 'continuing unrelated entries' <<<"$output" ||
    fail "nonzero selector must report its safe continuation"
grep -Fxq 'RTC_POSTGRES_TEST_SIZES=S,M' "$failed_env" ||
    fail "validated default size list must persist to later workflow steps"

single_selection="$temp/single-size-selection.json"
single_env="$temp/single-size.env"
if RTC_AZURE_TEST_REGIONS=centralus RTC_POSTGRES_TEST_SIZES=S \
    RTC_AZURE_SELECTION_FILE="$single_selection" GITHUB_ENV="$single_env" \
    FAKE_SELECTOR_STATUS=0 bash "$selector_scripts/azure-postgres-workflow.sh" \
    select-context fixture-probe >/dev/null 2>&1; then
    :
else
    fail "single-size selection fixture should succeed"
fi
[[ "$(cat "$SIZE_LOG")" == S ]] || fail "selector must receive the single configured size"
grep -Fxq 'RTC_POSTGRES_TEST_SIZES=S' "$single_env" ||
    fail "validated single-size list must persist to the PostgreSQL deployment step"

export RTC_AZURE_SELECTION_FILE="$temp/selection.json" GITHUB_STEP_SUMMARY="$temp/summary.md"
for status in selected capacity_exhausted unsupported probe_error deadline_exceeded; do
    jq -n --arg status "$status" '{version:1,status:$status,deadlineEpochSeconds:123456,
        secret:"DO_NOT_PRINT",attempts:[{region:"centralus",size:"M",skuName:"Standard_D2ds_v5",
        tier:"GeneralPurpose",outcome:"capacity_exhausted",errorCode:"SkuNotAvailable",durationSeconds:12}]}' \
        >"$RTC_AZURE_SELECTION_FILE"
    : >"$GITHUB_STEP_SUMMARY"
    bash "$script" summary
    grep -Fq "Final selection status: **$status**" "$GITHUB_STEP_SUMMARY" || fail "status summary"
    grep -Fq '| centralus | M | Standard_D2ds_v5 | GeneralPurpose | capacity_exhausted | SkuNotAvailable | 12 |' \
        "$GITHUB_STEP_SUMMARY" || fail "attempt table"
    ! grep -q DO_NOT_PRINT "$GITHUB_STEP_SUMMARY" || fail "unexpected fields leaked"
done
printf '%s\n' '{}' >"$RTC_AZURE_SELECTION_FILE"
if bash "$script" summary 2>/dev/null; then fail "malformed summary"; fi
rm "$RTC_AZURE_SELECTION_FILE"
if bash "$script" summary 2>/dev/null; then fail "missing summary"; fi

mkdir "$temp/bin"
export CALL_LOG="$temp/calls" GROUP_STATE="$temp/state"
cat >"$temp/bin/az" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "$*" >>"$CALL_LOG"
if [[ "${SLOW_AZ_COMMAND:-}" == "$2" ]]; then
    exec "$SLOW_AZ_HELPER"
fi
command="$2"
group=""
query=""
tags=()
while (($#)); do
    case "$1" in
        --name) group="$2"; shift 2 ;;
        --query) query="$2"; shift 2 ;;
        --tags)
            shift
            while (($#)) && [[ "$1" != --* ]]; do tags+=("$1"); shift; done
            ;;
        *) shift ;;
    esac
done
state_line() { grep -F "$1|" "$GROUP_STATE" | head -n 1; }
case "$command" in
    list) [[ "${LIST_FAILS:-}" != true ]] || exit 1; cut -d'|' -f1 "$GROUP_STATE" ;;
    exists)
        if grep -Fq "$group|" "$GROUP_STATE"; then echo true; else echo false; fi
        ;;
    show)
        line="$(state_line "$group")"
        [[ -n "$line" ]] || exit 1
        if [[ "$query" == tags.rtcPostgresSelectorOwner ]]; then
            IFS='|' read -r _ key value <<<"$line"
            [[ "$key" == rtcPostgresSelectorOwner ]] && echo "$value"
        elif [[ "$query" == tags.rtcAzureTestGroupOwner ]]; then
            IFS='|' read -r _ key value <<<"$line"
            [[ "$key" == rtcAzureTestGroupOwner ]] && echo "$value"
        fi
        ;;
    delete)
        if [[ "${DELETE_FAILS:-}" == true ]]; then exit 1; fi
        if [[ "${DELETE_STUCK:-}" != true ]]; then
            grep -Fv "$group|" "$GROUP_STATE" >"$GROUP_STATE.next" || true
            mv "$GROUP_STATE.next" "$GROUP_STATE"
        fi
        ;;
    create)
        owner_tag=""
        owner_value=""
        for tag in "${tags[@]}"; do
            case "$tag" in rtcPostgresSelectorOwner=*) owner_tag=rtcPostgresSelectorOwner; owner_value="${tag#*=}" ;;
                rtcAzureTestGroupOwner=*) owner_tag=rtcAzureTestGroupOwner; owner_value="${tag#*=}" ;;
            esac
        done
        if [[ -n "${ASSERT_CREATE_LOG:-}" && "$owner_tag" == rtcAzureTestGroupOwner ]] &&
            ! grep -Fq "Creating main resource group '$group' with rtcAzureTestGroupOwner=$owner_value." \
                "$ASSERT_CREATE_LOG"; then
            exit 91
        fi
        case "${CREATE_FAILURE_MODE:-}" in
            owned)
                printf '%s|%s|%s\n' "$group" "$owner_tag" "$owner_value" >>"$GROUP_STATE"
                exit 1
                ;;
            foreign)
                printf '%s|rtcAzureTestGroupOwner|%s\n' "$group" "$FOREIGN_OWNER_TOKEN" >>"$GROUP_STATE"
                exit 1
                ;;
            absent) exit 1 ;;
            timeout) exit 124 ;;
            late)
                printf '%s|%s|%s\n' "$group" "$owner_tag" "$owner_value" >"$GROUP_STATE.pending"
                exit 1
                ;;
        esac
        printf '%s|%s|%s\n' "$group" "$owner_tag" "$owner_value" >>"$GROUP_STATE"
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$temp/bin/az"
export PATH="$temp/bin:$PATH" GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=3 AZURE_SUBSCRIPTION_ID=test
export SLOW_AZ_HELPER="$temp/slow-az.py" SLOW_AZ_PIDS="$temp/slow-az.pids"
cat >"$SLOW_AZ_HELPER" <<'PY'
#!/usr/bin/env python3
import os
import signal
import time

signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = os.fork()
if child:
    with open(os.environ["SLOW_AZ_PIDS"], "w", encoding="ascii") as output:
        output.write(f"{os.getpid()}\n{child}\n")
time.sleep(20)
PY
chmod +x "$SLOW_AZ_HELPER"
token_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
token_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
for kind in nightly rc; do
    group="rrttest-$kind-123-2-probe-$token_a"
    printf '%s|rtcPostgresSelectorOwner|%s\n' "$group" "$token_a" >"$GROUP_STATE"
    : >"$CALL_LOG"
    bash "$script" cleanup-probe "$group"
    grep -q "group delete --name $group --subscription test" "$CALL_LOG" ||
        fail "exact owned group"
    ! grep -q -- --no-wait "$CALL_LOG" || fail "must confirm deletion"
    : >"$CALL_LOG"
    bash "$script" cleanup-probe "$group"
    ! grep -q 'group delete' "$CALL_LOG" || fail "missing group is idempotent"
done
: >"$CALL_LOG"
bash "$script" cleanup-probe ''
for group in caller-owned rrttest-nightly-124-2-probe-$token_a rrttest-rc-123-4-probe-$token_a \
    rrttest-nightly-123-0-probe rrttest-rc-123-x-probe \
    rrttest-nightly-123-2-probe-suffix; do
    if bash "$script" cleanup-probe "$group" 2>/dev/null; then fail "ownership guard"; fi
done
[[ ! -s "$CALL_LOG" ]] || fail "must reject before Azure calls"
group="rrttest-nightly-123-2-probe-$token_a"
printf '%s|rtcPostgresSelectorOwner|%s\n' "$group" "$token_a" >"$GROUP_STATE"
if DELETE_FAILS=true bash "$script" cleanup-probe "$group" 2>/dev/null; then
    fail "delete error"
fi
if DELETE_STUCK=true bash "$script" cleanup-probe "$group" 2>/dev/null; then
    fail "delete must be confirmed"
fi
for attempt in 1 2 3; do
    : >"$GROUP_STATE"
    bash "$script" cleanup-probe "rrttest-nightly-123-$attempt-probe"
done
if GITHUB_RUN_ID=124 bash "$script" cleanup-probe "rrttest-nightly-123-2-probe-$token_a" 2>/dev/null; then
    fail "mismatched run ID"
fi
if GITHUB_RUN_ATTEMPT=invalid bash "$script" cleanup-probe "rrttest-nightly-123-2-probe-$token_a" 2>/dev/null; then
    fail "invalid current attempt"
fi

# Cleanup discovers groups by run ID and attempt, then requires each group's owner tag.
for kind in nightly rc; do
    main2="rrttest-$kind-123-2-$token_a"
    probe2="rrttest-$kind-123-2-probe-$token_b"
    main4="rrttest-$kind-123-4-$token_a"
    probe4="rrttest-$kind-123-4-probe-$token_b"
    cat >"$GROUP_STATE" <<EOF
$main2|rtcAzureTestGroupOwner|$token_a
$probe2|rtcPostgresSelectorOwner|$token_b
$main4|rtcAzureTestGroupOwner|$token_a
$probe4|rtcPostgresSelectorOwner|$token_b
rrttest-$kind-123-5-$token_a|rtcAzureTestGroupOwner|$token_a
rrttest-$kind-123-5-probe-$token_b|rtcPostgresSelectorOwner|$token_b
rrttest-$kind-123-2-extra||
rrttest-$kind-123-x-probe||
rrttest-$kind-124-2-$token_a|rtcAzureTestGroupOwner|$token_a
rrttest-other-123-2-$token_a|rtcAzureTestGroupOwner|$token_a
EOF
    : >"$CALL_LOG"
    GITHUB_RUN_ATTEMPT=4 bash "$script" cleanup-run-groups "$kind"
    for group in "$main2" "$probe2" "$main4" "$probe4"; do
        grep -Fq "delete --name $group --subscription test" "$CALL_LOG" ||
            fail "earlier-attempt cleanup discovery: $group"
    done
    ! grep -Fq -- --no-wait "$CALL_LOG" || fail "all owned group deletions must be confirmed"
    for group in "rrttest-$kind-123-5-$token_a" "rrttest-$kind-123-5-probe-$token_b" \
        "rrttest-$kind-123-2-extra" "rrttest-$kind-123-x-probe" \
        "rrttest-$kind-124-2-$token_a" "rrttest-other-123-2-$token_a"; do
        ! grep -Fq "delete --name $group " "$CALL_LOG" ||
            fail "ignored unrelated group: $group"
    done
done

# Current outputs do not hide earlier groups, and only matching owner tags permit deletion.
for kind in nightly rc; do
    main1="rrttest-$kind-123-1-$token_a"
    probe1="rrttest-$kind-123-1-probe-$token_b"
    main2="rrttest-$kind-123-2-$token_a"
    probe2="rrttest-$kind-123-2-probe-$token_b"
    cat >"$GROUP_STATE" <<EOF
$main1|rtcAzureTestGroupOwner|$token_a
$probe1|rtcPostgresSelectorOwner|$token_b
$main2|rtcAzureTestGroupOwner|$token_a
$probe2|rtcPostgresSelectorOwner|$token_b
rrttest-$kind-123-3-$token_a|rtcAzureTestGroupOwner|$token_a
rrttest-$kind-123-3-probe-$token_b|rtcPostgresSelectorOwner|$token_b
rrttest-$kind-124-1-$token_a|rtcAzureTestGroupOwner|$token_a
rrttest-other-123-1-$token_a|rtcAzureTestGroupOwner|$token_a
EOF
    : >"$CALL_LOG"
    AZURE_RESOURCE_GROUP="$main2" PROBE_RESOURCE_GROUP="$probe2" GITHUB_RUN_ATTEMPT=2 \
        bash "$script" cleanup-run-groups "$kind"
    for group in "$main1" "$probe1" "$main2" "$probe2"; do
        grep -Fq "delete --name $group --subscription test" "$CALL_LOG" ||
            fail "cleanup with current outputs missed earlier group: $group"
    done
    for group in "rrttest-$kind-123-3-$token_a" "rrttest-$kind-123-3-probe-$token_b" \
        "rrttest-$kind-124-1-$token_a" "rrttest-other-123-1-$token_a"; do
        ! grep -Fq "delete --name $group " "$CALL_LOG" ||
            fail "cleanup deleted an unowned or future group: $group"
    done
done

# Exact legacy names and forged/mismatched owner tags are never deleted.
for kind in nightly rc; do
    cat >"$GROUP_STATE" <<EOF
rrttest-$kind-123-2||
rrttest-$kind-123-2-probe||
rrttest-$kind-123-2-$token_a|rtcAzureTestGroupOwner|$token_b
rrttest-$kind-123-2-probe-$token_a|rtcPostgresSelectorOwner|$token_b
EOF
    : >"$CALL_LOG"
    if bash "$script" cleanup-run-groups "$kind" 2>/dev/null; then fail "unowned groups must fail cleanup"; fi
    ! grep -q 'group delete' "$CALL_LOG" || fail "unowned groups must not be deleted"
done

: >"$GROUP_STATE"
LIST_FAILS=true bash "$script" cleanup-run-groups nightly 2>/dev/null &&
    fail "resource group discovery failure"
for kind in nightly rc; do
    printf 'rrttest-%s-123-2-%s|rtcAzureTestGroupOwner|%s\n' "$kind" "$token_a" "$token_a" >"$GROUP_STATE"
    DELETE_FAILS=true GITHUB_RUN_ATTEMPT=3 bash "$script" cleanup-run-groups "$kind" \
        2>/dev/null && fail "resource group delete failure"
    DELETE_STUCK=true GITHUB_RUN_ATTEMPT=3 bash "$script" cleanup-run-groups "$kind" \
        2>/dev/null && fail "resource group deletion must be confirmed"
done

# Main-group creation refuses an existing exact name and marks only its new target as owned.
for kind in nightly rc; do
    : >"$GROUP_STATE"
    group="rrttest-$kind-123-3-$token_a"
    create_log="$temp/create-$kind.log"
    : >"$create_log"
    # The mock checks the log line before allowing the create request to proceed.
    # shellcheck disable=SC2094
    ASSERT_CREATE_LOG="$create_log" bash "$script" create-main "$kind" "$group" westus3 "$token_a" \
        >"$create_log" 2>&1
    grep -Fq "Creating main resource group '$group' with rtcAzureTestGroupOwner=$token_a." "$create_log" ||
        fail "main group recovery target must be logged before create"
    grep -Fq "$group|rtcAzureTestGroupOwner|$token_a" "$GROUP_STATE" ||
        fail "main group ownership tag"
    : >"$CALL_LOG"
    bash "$script" cleanup-run-groups "$kind"
    grep -q 'group delete' "$CALL_LOG" && [[ ! -s "$GROUP_STATE" ]] ||
        fail "owned main group cleanup"
    printf '%s||\n' "$group" >"$GROUP_STATE"
    : >"$CALL_LOG"
    if bash "$script" create-main "$kind" "$group" westus3 "$token_a" 2>/dev/null; then
        fail "existing main group must be rejected"
    fi
    ! grep -q '^group create' "$CALL_LOG" || fail "must not update existing main group"
    grep -Fq "$group||" "$GROUP_STATE" || fail "existing main group preserved"

    for mode in owned foreign absent timeout; do
        : >"$GROUP_STATE"
        : >"$CALL_LOG"
        if CREATE_FAILURE_MODE="$mode" FOREIGN_OWNER_TOKEN="$token_b" \
            bash "$script" create-main "$kind" "$group" westus3 "$token_a" \
            >/dev/null 2>&1; then
            fail "$kind main-group $mode creation failure"
        fi
        ! grep -q 'group delete' "$CALL_LOG" || fail "$kind $mode failure must not delete an unconfirmed group"
        case "$mode" in
            owned)
                grep -Fq "$group|rtcAzureTestGroupOwner|$token_a" "$GROUP_STATE" ||
                    fail "$kind partial owned group must be left for the cleanup job"
                ;;
            foreign)
                grep -Fq "$group|rtcAzureTestGroupOwner|$token_b" "$GROUP_STATE" ||
                    fail "$kind foreign-tagged group must be preserved"
                ;;
            absent|timeout)
                [[ ! -s "$GROUP_STATE" ]] || fail "$kind $mode failure must leave absent group state"
                ;;
        esac
    done
done

: >"$GROUP_STATE"
late_group="rrttest-nightly-123-3-$token_a"
late_log="$temp/late-create.log"
if output=$(CREATE_FAILURE_MODE=late \
    bash "$script" create-main nightly "$late_group" westus3 "$token_a" 2>&1); then
    fail "late main-group create must be reported as uncertain"
fi
printf '%s\n' "$output" >"$late_log"
grep -Fq "Creating main resource group '$late_group' with rtcAzureTestGroupOwner=$token_a." <<<"$output" ||
    fail "interrupted main-group create must log its exact recovery target before Azure work"
grep -Fq "Inspect '$late_group' and its ownership tag" <<<"$output" ||
    fail "uncertain main-group create must direct operators to the logged recovery target"
[[ ! -s "$GROUP_STATE" ]] || fail "late-create fixture must initially remain absent"
# Complete the remote operation after the client exits, without a client orphan.
cat "$GROUP_STATE.pending" >>"$GROUP_STATE"
grep -Fq "$late_group|rtcAzureTestGroupOwner|$token_a" "$GROUP_STATE" ||
    fail "late Azure create must materialize the logged recovery target"

assert_slow_processes_stopped() {
    python3 - "$SLOW_AZ_PIDS" <<'PY' || fail "workflow watchdog left a process running"
import pathlib
import sys

for pid in pathlib.Path(sys.argv[1]).read_text().splitlines():
    try:
        state = pathlib.Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1][0]
    except FileNotFoundError:
        continue
    if state != "Z":
        raise SystemExit(f"Process {pid} is still running ({state})")
PY
}
for slow_command in exists show delete; do
    : >"$CALL_LOG"
    printf '%s|rtcAzureTestGroupOwner|%s\n' "$late_group" "$token_a" >"$GROUP_STATE"
    rm -f -- "$SLOW_AZ_PIDS"
    started_seconds=$SECONDS
    if output=$({
        export SLOW_AZ_COMMAND="$slow_command"
        set -- regions
        # shellcheck source=/dev/null
        source "$script" >/dev/null
        # shellcheck disable=SC2034 # Read by the sourced cleanup helper.
        cleanup_deadline=$((SECONDS + 2))
        delete_and_confirm_resource_group "$late_group" rtcAzureTestGroupOwner "$token_a"
    } 2>&1); then fail "$slow_command timeout must fail cleanup"; fi
    ((SECONDS - started_seconds < 8)) || fail "workflow $slow_command exceeded its cleanup budget"
    [[ -s "$SLOW_AZ_PIDS" ]] || fail "workflow $slow_command must exercise the watchdog"
    assert_slow_processes_stopped
    grep -Fq "$late_group|rtcAzureTestGroupOwner|$token_a" "$GROUP_STATE" ||
        fail "uncertain workflow cleanup must preserve the resource group"
    if [[ "$slow_command" != delete ]] && grep -q '^group delete ' "$CALL_LOG"; then
        fail "uncertain existence or ownership must not authorize deletion"
    fi
done

: >"$CALL_LOG"
: >"$GROUP_STATE"
rm -f -- "$SLOW_AZ_PIDS"
started_seconds=$SECONDS
if output=$(SLOW_AZ_COMMAND=create timeout --signal=TERM --kill-after=4 2 \
    bash "$script" create-main nightly "$late_group" westus3 "$token_a" 2>&1); then
    fail "cancelled main-group creation must fail"
fi
((SECONDS - started_seconds < 8)) || fail "workflow cancellation must stop TERM-ignoring children"
assert_slow_processes_stopped
grep -Fq "Creating main resource group '$late_group' with rtcAzureTestGroupOwner=$token_a." <<<"$output" ||
    fail "cancelled creation must log the exact recovery target"
! grep -q '^group delete ' "$CALL_LOG" ||
    fail "cancelled main creation must leave ownership verification to the cleanup job"
echo "Azure PostgreSQL workflow tests passed"
