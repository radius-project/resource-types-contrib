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

# Usage: select-azure-test-location.sh <probe-resource-group-prefix> <region>...
# The selector appends a random 128-bit suffix; callers must pass a prefix, not
# a resource-group name that they expect the selector to create verbatim.
# RTC_AZURE_TEST_REGIONS, when set, overrides positional regions (comma-separated).
# RTC_POSTGRES_TEST_SIZES defaults to S,M. Sizes are the outer loop.
# At most four distinct regions and two sizes (eight tuples); duplicates retain
# their first position. Raw lists are limited to 32 entries.
# RTC_POSTGRES_SELECTION_DEADLINE_SECONDS=3600 (1..3600) bounds selection and
# later deployment recovery together, including time between workflow steps.
# Each create is capped by the remaining deadline and its own limit (max 900).
# RTC_POSTGRES_CLEANUP_RESERVE_SECONDS defaults to 900 (1..900) and may shorten
# cleanup time beyond the shared deadline.
# Optional RTC_AZURE_SELECTION_FILE receives version 1 JSON. Only "selected"
# confirms capacity. Consumers MUST fail the PostgreSQL check for other states.
# For legacy callers, stdout is always the selected or first region and exit is
# 0 after a completed search, even if capacity was not found. Invalid settings,
# result write errors, and group cleanup failures exit 1. Progress is on stderr.

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-azure-postgres-test.sh
source "$script_dir/lib-azure-postgres-test.sh"

if (($# < 1)); then
    echo "Usage: $0 <probe-resource-group> <region>..." >&2
    exit 1
fi
requested_probe_rg="$1"
shift
regions=("$@")
if [[ -v RTC_AZURE_TEST_REGIONS ]]; then
    [[ "$RTC_AZURE_TEST_REGIONS" =~ ^[a-z0-9]+(,[a-z0-9]+)*$ ]] ||
        { echo "Error: invalid region list." >&2; exit 1; }
    IFS=',' read -r -a regions <<<"$RTC_AZURE_TEST_REGIONS"
fi
size_list="$(rtc_postgres_normalize_test_sizes)" || exit 1
IFS=',' read -r -a sizes <<<"$size_list"
deadline_seconds="${RTC_POSTGRES_SELECTION_DEADLINE_SECONDS-3600}"
create_timeout="${RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS-900}"
delete_timeout="${RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS-900}"
cleanup_reserve="$(rtc_postgres_cleanup_reserve_seconds)" || exit 1
if [[ ! "$requested_probe_rg" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    ((${#requested_probe_rg} + 33 > 90)) ||
    ((${#regions[@]} == 0 || ${#regions[@]} > 32 || ${#sizes[@]} == 0 || ${#sizes[@]} > 32)) ||
    ! rtc_postgres_positive_limit "$deadline_seconds" 3600 ||
    ! rtc_postgres_positive_limit "$create_timeout" 900 ||
    ! rtc_postgres_positive_limit "$delete_timeout" 900 ||
    ! rtc_postgres_positive_limit "$cleanup_reserve" 900; then
    echo "Error: invalid selection candidates or time limits." >&2
    exit 1
fi
candidates=()
test_sizes=()
for location in "${regions[@]}"; do
    [[ "$location" =~ ^[a-z0-9]+$ ]] || { echo "Error: invalid region." >&2; exit 1; }
    if [[ ! " ${candidates[*]} " == *" $location "* ]]; then candidates+=("$location"); fi
done
for size in "${sizes[@]}"; do
    rtc_postgres_test_tuple "$size" || exit 1
    if [[ ! " ${test_sizes[*]} " == *" $size "* ]]; then test_sizes+=("$size"); fi
done
if ((${#candidates[@]} > 4 || ${#test_sizes[@]} > 2)); then
    echo "Error: selection permits at most four regions and two sizes." >&2
    exit 1
fi

subscription_args=()
if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then subscription_args=(--subscription "$AZURE_SUBSCRIPTION_ID"); fi
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/rtc-postgres-selection-XXXXXX")"
selection_status="probe_error"
selected_location="${candidates[0]}"
selected_postgres="null"
attempt_records="[]"
group_started=false
deadline=$((SECONDS + deadline_seconds))
deadline_epoch=$(( $(date +%s) + deadline_seconds ))
cleanup_deadline=$((deadline + cleanup_reserve))
probe_rg=""
probe_owner_token=""
group_create_attempted=false
RUN_OUTPUT=""

run_before_deadline() {
    local deadline_at="$1" requested_limit="$2" remaining status=0
    shift 2
    remaining=$((deadline_at - SECONDS))
    ((remaining > 0)) || return 124
    if ((requested_limit > remaining)); then requested_limit="$remaining"; fi
    rtc_run_command --timeout "$requested_limit" --quiet "$@" || status=$?
    RUN_OUTPUT="$RTC_COMMAND_OUTPUT"
    return "$status"
}

group_has_owner_tag() {
    local deadline_at="$1" owner_tag
    run_before_deadline "$deadline_at" 30 az group show "${subscription_args[@]}" \
        --name "$probe_rg" --query "tags.rtcPostgresSelectorOwner" --output tsv 2>/dev/null ||
        return 1
    owner_tag="$RUN_OUTPUT"
    [[ "$owner_tag" == "$probe_owner_token" ]]
}

delete_owned_probe_group() {
    local remaining exists
    run_before_deadline "$cleanup_deadline" 30 az group exists "${subscription_args[@]}" \
        --name "$probe_rg" --output tsv || return 1
    exists="$RUN_OUTPUT"
    [[ "$exists" == false ]] && return 0
    [[ "$exists" == true ]] || return 1
    group_has_owner_tag "$cleanup_deadline" || return 1
    remaining=$((cleanup_deadline - SECONDS))
    ((remaining > 0)) || return 1
    if ((remaining > delete_timeout)); then remaining="$delete_timeout"; fi
    run_before_deadline "$cleanup_deadline" "$remaining" az group delete "${subscription_args[@]}" \
        --name "$probe_rg" --yes --only-show-errors --output none >&2 || return 1
    run_before_deadline "$cleanup_deadline" 30 az group exists "${subscription_args[@]}" \
        --name "$probe_rg" --output tsv || return 1
    exists="$RUN_OUTPUT"
    [[ "$exists" == false ]]
}

# shellcheck disable=SC2329
finish() {
    local status=$? deadline_expired=false
    [[ "$selection_status" != deadline_exceeded ]] || deadline_expired=true
    trap - EXIT INT TERM
    if [[ "$group_create_attempted" == true ]]; then
        if group_has_owner_tag "$cleanup_deadline"; then
            group_started=true
            echo "Interrupted or uncertain probe group '$probe_rg' has matching rtcPostgresSelectorOwner=$probe_owner_token; attempting cleanup." >&2
        else
            echo "Error: probe group creation for '$probe_rg' was interrupted or uncertain; ownership could not be confirmed, so it was not deleted." >&2
            echo "Recovery: inspect '$probe_rg' for rtcPostgresSelectorOwner=$probe_owner_token. An immediate absence does not rule out a late create; check again after the Azure request settles." >&2
            selection_status="probe_error"; selected_postgres="null"
            selected_location="${candidates[0]}"; status=1
        fi
    fi
    if [[ "$group_started" == true ]] && ! delete_owned_probe_group; then
        echo "Error: owned probe group '$probe_rg' cleanup failed or ownership could not be confirmed." >&2
        echo "Recovery: inspect '$probe_rg' and verify rtcPostgresSelectorOwner=$probe_owner_token before removing it." >&2
        selection_status="probe_error"; selected_postgres="null"
        selected_location="${candidates[0]}"; status=1
    fi
    if [[ "$deadline_expired" == true ]]; then
        for size in "${test_sizes[@]}"; do
            rtc_postgres_test_tuple "$size"
            for location in "${candidates[@]}"; do
                attempt_records="$(jq -c --arg region "$location" --arg size "$size" \
                    --arg skuName "$postgres_sku" --arg tier "$postgres_tier" '
                    if any(.[]; .region == $region and .size == $size) then .
                    else . + [{region:$region,size:$size,skuName:$skuName,tier:$tier,
                        outcome:"not_attempted",errorCode:"DeadlineExceeded",
                        durationSeconds:0,cleanup:"not_required"}] end' <<<"$attempt_records")"
            done
        done
    fi
    if [[ -n "${RTC_AZURE_SELECTION_FILE:-}" ]]; then
        jq -n --arg status "$selection_status" --arg location "$selected_location" \
            --argjson postgres "$selected_postgres" --argjson attempts "$attempt_records" \
            --argjson deadlineEpochSeconds "$deadline_epoch" --argjson settings "$(rtc_postgres_test_settings)" \
            '{version: 1, status: $status, location: $location, attempts: $attempts,
              deadlineEpochSeconds: $deadlineEpochSeconds, settings: $settings}
             + (if $status == "selected" then {postgres: $postgres} else {} end)' \
            >"$RTC_AZURE_SELECTION_FILE" || status=1
    fi
    rm -rf -- "$work_dir"
    printf '%s\n' "$selected_location"
    exit "$status"
}
handle_signal() {
    trap - INT TERM
    exit 1
}
trap finish EXIT
trap handle_signal INT TERM

# Refuse a supplied name that already exists. Azure group create is an upsert.
if ! run_before_deadline "$deadline" 30 az group exists "${subscription_args[@]}" \
    --name "$requested_probe_rg" --output tsv; then
    if ((SECONDS >= deadline)); then
        selection_status="deadline_exceeded"
        echo "Error: PostgreSQL selection deadline expired while checking the supplied probe group." >&2
    else
        echo "Error: could not verify supplied probe group '$requested_probe_rg'; refusing to create or delete it." >&2
    fi
    exit 1
fi
existing_group="$RUN_OUTPUT"
if ((SECONDS >= deadline)); then
    selection_status="deadline_exceeded"
    echo "Error: PostgreSQL selection deadline expired while checking the supplied probe group." >&2
    exit 1
fi
if [[ "$existing_group" == true ]]; then
    echo "Error: supplied probe group '$requested_probe_rg' already exists; refusing to update or delete it." >&2
    exit 1
fi
if [[ "$existing_group" != false ]]; then
    echo "Error: Azure returned an unknown state for supplied probe group '$requested_probe_rg'; refusing to continue." >&2
    exit 1
fi

# A random target prevents concurrent selectors from upserting the same RG.
probe_owner_token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
if [[ ! "$probe_owner_token" =~ ^[a-f0-9]{32}$ ]]; then
    echo "Error: could not create a valid unique probe group name from '$requested_probe_rg'." >&2
    exit 1
fi
probe_rg="${requested_probe_rg}-${probe_owner_token}"
if ! run_before_deadline "$deadline" 30 az group exists "${subscription_args[@]}" \
    --name "$probe_rg" --output tsv; then
    if ((SECONDS >= deadline)); then
        selection_status="deadline_exceeded"
        echo "Error: PostgreSQL selection deadline expired while checking the unique probe group." >&2
    else
        echo "Error: could not verify unique probe group '$probe_rg'; refusing to create it." >&2
    fi
    exit 1
fi
existing_group="$RUN_OUTPUT"
if ((SECONDS >= deadline)); then
    selection_status="deadline_exceeded"
    echo "Error: PostgreSQL selection deadline expired while checking the unique probe group." >&2
    exit 1
fi
if [[ "$existing_group" != false ]]; then
    echo "Error: unique probe group '$probe_rg' is not confirmed absent; refusing to create or delete it." >&2
    exit 1
fi

# The group's location does not restrict its servers' locations.
group_create_limit=$((deadline - SECONDS))
if ((group_create_limit <= 0)); then
    selection_status="deadline_exceeded"
    echo "Error: PostgreSQL selection deadline expired before probe group creation." >&2
    exit 1
fi
echo "Creating PostgreSQL selector probe group '$probe_rg' with rtcPostgresSelectorOwner=$probe_owner_token." >&2
group_create_attempted=true
group_create_status=0
run_before_deadline "$deadline" "$group_create_limit" az group create "${subscription_args[@]}" \
    --name "$probe_rg" --location "${candidates[0]}" \
    --tags "creationTime=$(date +%s)" "rtcRunId=${GITHUB_RUN_ID:-local}" \
    "rtcRunAttempt=${GITHUB_RUN_ATTEMPT:-local}" "rtcPostgresSelectorOwner=$probe_owner_token" \
    --only-show-errors --output none >&2 || group_create_status=$?
if ((group_create_status != 0)); then
    if ((SECONDS >= deadline)); then selection_status="deadline_exceeded"; fi
    echo "Error: probe group creation failed or timed out for '$probe_rg'; the exit trap will verify ownership before cleanup." >&2
    exit 1
fi
if ! group_has_owner_tag "$deadline"; then
    echo "Error: probe group '$probe_rg' was created but its ownership tag could not be confirmed; it will not be deleted." >&2
    echo "Recovery: inspect '$probe_rg' and its rtcPostgresSelectorOwner tag before removing it." >&2
    exit 1
fi
group_started=true
group_create_attempted=false
selection_status="capacity_exhausted"
for size in "${test_sizes[@]}"; do
    rtc_postgres_test_tuple "$size"
    for location in "${candidates[@]}"; do
        remaining=$((deadline - SECONDS))
        if ((remaining <= 0)); then selection_status="deadline_exceeded"; break 2; fi
        limit="$create_timeout"
        if ((remaining < limit)); then limit="$remaining"; fi
        cleanup_limit=$((cleanup_deadline - SECONDS - limit))
        if ((cleanup_limit > delete_timeout)); then cleanup_limit="$delete_timeout"; fi
        started=$SECONDS
        status=0
        rm -f -- "$work_dir/probe.json"
        AZURE_RESOURCE_GROUP="$probe_rg" AZURE_LOCATION="$location" RTC_POSTGRES_TEST_SIZE="$size" \
            RTC_POSTGRES_PROBE_ATTEMPTS=1 RTC_POSTGRES_PROBE_WAIT_SECONDS=0 \
            RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS="$limit" \
            RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS="$cleanup_limit" \
            RTC_POSTGRES_PROBE_CLEANUP_DEADLINE_EPOCH="$((deadline_epoch + cleanup_reserve))" \
            RTC_POSTGRES_PROBE_RESULT_FILE="$work_dir/probe.json" \
            rtc_run_command --quiet bash \
                "$script_dir/probe-azure-postgres-capacity.sh" >&2 || status=$?
        duration=$((SECONDS - started))
        case "$status" in
            0) outcome="available" ;;
            2) outcome="capacity_exhausted" ;;
            3) outcome="timeout" ;;
            4) outcome="unsupported" ;;
            5) outcome="restricted" ;;
            *) outcome="probe_error" ;;
        esac
        error_code="UnknownError"
        cleanup="uncertain"
        diagnostic="null"
        if [[ -f "$work_dir/probe.json" ]] && jq -e --arg outcome "$outcome" \
            '.outcome == $outcome and (.errorCode | type == "string") and
             (.cleanup == "not_required" or .cleanup == "confirmed" or
              .cleanup == "failed" or .cleanup == "uncertain") and
             (if has("diagnostic") then
                 .diagnostic == null or (
                   (.diagnostic | type == "object") and
                   (.diagnostic.stage | type == "string" and
                     test("^(pre-create read|create|show|delete|confirm|deadline)$")) and
                   (.diagnostic.exitStatus | type == "number" and floor == .) and
                   (.diagnostic.errorCode | type == "string" and
                     test("^(none|[A-Za-z][A-Za-z0-9]*(,[A-Za-z][A-Za-z0-9]*)*)$")) and
                   (.diagnostic.firstError == null or (
                     (.diagnostic.firstError.stage | type == "string" and
                       test("^(pre-create read|create|show|delete|confirm|deadline)$")) and
                     (.diagnostic.firstError.exitStatus | type == "number" and floor == .) and
                     (.diagnostic.firstError.errorCode | type == "string" and
                       test("^(none|[A-Za-z][A-Za-z0-9]*(,[A-Za-z][A-Za-z0-9]*)*)$"))
                   )) and
                   (.diagnostic.outcomeBeforeCleanup == null or
                     (.diagnostic.outcomeBeforeCleanup | type == "string")) and
                   (.diagnostic.errorCodeBeforeCleanup == null or
                     (.diagnostic.errorCodeBeforeCleanup | type == "string" and
                       test("^(none|[A-Za-z][A-Za-z0-9]*(,[A-Za-z][A-Za-z0-9]*)*)$")))
                 )
               else true end)' "$work_dir/probe.json" >/dev/null; then
            error_code="$(jq -er '.errorCode | select(type == "string")' "$work_dir/probe.json")" || status=1
            cleanup="$(jq -r '.cleanup' "$work_dir/probe.json")"
            diagnostic="$(jq -c '.diagnostic // null' "$work_dir/probe.json")"
        else
            status=1; outcome="probe_error"
        fi
        if [[ "$cleanup" == failed ]] ||
            { [[ "$cleanup" != confirmed ]] && ((status == 0 || status == 2)); } ||
            { [[ "$cleanup" != not_required ]] && ((status == 4 || status == 5)); }; then
            status=1; outcome="probe_error"; error_code="CleanupUnconfirmed"
        fi
        if ((status == 4)) &&
            [[ ! "$error_code" =~ ^Unsupported(Version|Tier|Sku|Storage)$ ]]; then
            status=1
            outcome="probe_error"
        fi
        if ((status == 5)) && [[ "$error_code" != RegionRestricted ]]; then
            status=1
            outcome="probe_error"
        fi
        attempt_records="$(jq -c --arg region "$location" --arg size "$size" --arg skuName "$postgres_sku" \
            --arg tier "$postgres_tier" --arg outcome "$outcome" --arg errorCode "$error_code" --arg cleanup "$cleanup" \
            --argjson durationSeconds "$duration" --argjson diagnostic "$diagnostic" \
            '. + [{region: $region, size: $size, skuName: $skuName, tier: $tier,
                   outcome: $outcome, errorCode: $errorCode, durationSeconds: $durationSeconds,
                   cleanup:$cleanup}
                 + (if $diagnostic == null then {} else {diagnostic:$diagnostic} end)]' \
            <<<"$attempt_records")"
        echo "==> $location/$size ($postgres_sku): $outcome, code=$error_code, ${duration}s" >&2
        # Cleanup failure and other provider errors must not be hidden by a deadline.
        if ((status != 0 && status != 2 && status != 3 && status != 4 && status != 5)); then
            selection_status="probe_error"; break 2
        fi
        if ((SECONDS >= deadline)); then selection_status="deadline_exceeded"; break 2; fi
        case "$status" in
            0)
                selection_status="selected"
                selected_location="$location"
                selected_postgres="$(jq -n --arg size "$size" --arg skuName "$postgres_sku" \
                    --arg tier "$postgres_tier" '{size: $size, skuName: $skuName, tier: $tier}')"
                break 2 ;;
            3) selection_status="probe_error"; break 2 ;;
        esac
    done
done
if [[ "$selection_status" == "capacity_exhausted" ]] &&
    ! jq -e 'any(.[]; .outcome == "capacity_exhausted")' <<<"$attempt_records" >/dev/null; then
    if jq -e 'length > 0 and all(.[]; .outcome == "unsupported")' <<<"$attempt_records" >/dev/null; then
        selection_status="unsupported"
    elif jq -e 'length > 0 and all(.[]; .outcome == "restricted")' <<<"$attempt_records" >/dev/null; then
        selection_status="restricted"
    elif jq -e 'length > 0 and all(.[]; .outcome == "unsupported" or .outcome == "restricted")' \
        <<<"$attempt_records" >/dev/null; then
        selection_status="catalog_unavailable"
    fi
fi
if [[ "$selection_status" != "selected" ]]; then
    echo "::error::PostgreSQL selection: $selection_status. No PostgreSQL tuple was selected; $selected_location is for unrelated tests only." >&2
fi
