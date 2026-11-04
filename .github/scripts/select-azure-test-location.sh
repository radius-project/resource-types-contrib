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
# Cleanup may use up to 900 seconds beyond the shared deadline.
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
size_list="${RTC_POSTGRES_TEST_SIZES-S,M}"
[[ "$size_list" =~ ^[SM](,[SM])*$ ]] ||
    { echo "Error: invalid size list." >&2; exit 1; }
IFS=',' read -r -a sizes <<<"$size_list"
deadline_seconds="${RTC_POSTGRES_SELECTION_DEADLINE_SECONDS-3600}"
create_timeout="${RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS-900}"
delete_timeout="${RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS-900}"
if [[ ! "$requested_probe_rg" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    ((${#requested_probe_rg} + 33 > 90)) ||
    ((${#regions[@]} == 0 || ${#regions[@]} > 32 || ${#sizes[@]} == 0 || ${#sizes[@]} > 32)) ||
    ! rtc_postgres_positive_limit "$deadline_seconds" 3600 ||
    ! rtc_postgres_positive_limit "$create_timeout" 900 ||
    ! rtc_postgres_positive_limit "$delete_timeout" 900; then
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
cleanup_deadline=$((deadline + 900))
probe_rg=""
probe_owner_token=""

group_has_owner_tag() {
    local owner_tag
    owner_tag="$(timeout --kill-after=10 30 az group show "${subscription_args[@]}" \
        --name "$probe_rg" --query "tags.rtcPostgresSelectorOwner" --output tsv 2>/dev/null)" ||
        return 1
    [[ "$owner_tag" == "$probe_owner_token" ]]
}

delete_owned_probe_group() {
    local remaining exists
    exists="$(timeout --kill-after=10 30 az group exists "${subscription_args[@]}" \
        --name "$probe_rg" --output tsv)" || return 1
    [[ "$exists" == false ]] && return 0
    [[ "$exists" == true ]] || return 1
    group_has_owner_tag || return 1
    remaining=$((cleanup_deadline - SECONDS))
    ((remaining > 0)) || return 1
    if ((remaining > delete_timeout)); then remaining="$delete_timeout"; fi
    timeout --kill-after=10 "$remaining" az group delete "${subscription_args[@]}" \
        --name "$probe_rg" --yes --only-show-errors --output none >&2 || return 1
    remaining=$((cleanup_deadline - SECONDS))
    ((remaining > 0)) || return 1
    if ((remaining > 30)); then remaining=30; fi
    exists="$(timeout --kill-after=10 "$remaining" az group exists "${subscription_args[@]}" \
        --name "$probe_rg" --output tsv)" || return 1
    [[ "$exists" == false ]]
}

# shellcheck disable=SC2329
finish() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "$group_started" == true ]] && ! delete_owned_probe_group; then
        echo "Error: owned probe group '$probe_rg' cleanup failed or ownership could not be confirmed." >&2
        echo "Recovery: inspect the resource group and its rtcPostgresSelectorOwner tag before removing it." >&2
        selection_status="probe_error"; selected_postgres="null"
        selected_location="${candidates[0]}"; status=1
    fi
    if [[ -n "${RTC_AZURE_SELECTION_FILE:-}" ]]; then
        jq -n --arg status "$selection_status" --arg location "$selected_location" \
            --argjson postgres "$selected_postgres" --argjson attempts "$attempt_records" \
            --argjson deadlineEpochSeconds "$deadline_epoch" \
            '{version: 1, status: $status, location: $location, attempts: $attempts,
              deadlineEpochSeconds: $deadlineEpochSeconds}
             + (if $status == "selected" then {postgres: $postgres} else {} end)' \
            >"$RTC_AZURE_SELECTION_FILE" || status=1
    fi
    rm -rf -- "$work_dir"
    printf '%s\n' "$selected_location"
    exit "$status"
}
trap finish EXIT
trap 'exit 1' INT TERM

# Refuse a supplied name that already exists. Azure group create is an upsert.
existing_group="$(timeout --kill-after=10 30 az group exists "${subscription_args[@]}" \
    --name "$requested_probe_rg" --output tsv)" || {
    echo "Error: could not verify supplied probe group '$requested_probe_rg'; refusing to create or delete it." >&2
    exit 1
}
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
existing_group="$(timeout --kill-after=10 30 az group exists "${subscription_args[@]}" \
    --name "$probe_rg" --output tsv)" || {
    echo "Error: could not verify unique probe group '$probe_rg'; refusing to create it." >&2
    exit 1
}
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
if ! timeout --kill-after=10 "$group_create_limit" az group create "${subscription_args[@]}" \
    --name "$probe_rg" --location "${candidates[0]}" \
    --tags "creationTime=$(date +%s)" "rtcRunId=${GITHUB_RUN_ID:-local}" \
    "rtcRunAttempt=${GITHUB_RUN_ATTEMPT:-local}" "rtcPostgresSelectorOwner=$probe_owner_token" \
    --only-show-errors --output none >&2; then
    if ((SECONDS >= deadline)); then selection_status="deadline_exceeded"; fi
    if group_has_owner_tag; then
        group_started=true
        echo "Error: probe group creation failed after creating an owned partial group '$probe_rg'; cleanup will be attempted." >&2
    else
        echo "Error: probe group creation failed or timed out; ownership of '$probe_rg' cannot be proven, so it will not be deleted." >&2
        echo "Recovery: inspect '$probe_rg' and remove it only if it is the partial group from this selector attempt." >&2
    fi
    exit 1
fi
if ! group_has_owner_tag; then
    echo "Error: probe group '$probe_rg' was created but its ownership tag could not be confirmed; it will not be deleted." >&2
    echo "Recovery: inspect '$probe_rg' and its rtcPostgresSelectorOwner tag before removing it." >&2
    exit 1
fi
group_started=true
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
            RTC_POSTGRES_PROBE_RESULT_FILE="$work_dir/probe.json" \
            "$script_dir/probe-azure-postgres-capacity.sh" >&2 || status=$?
        duration=$((SECONDS - started))
        case "$status" in
            0) outcome="available" ;;
            2) outcome="capacity_exhausted" ;;
            3) outcome="timeout" ;;
            *) outcome="probe_error" ;;
        esac
        error_code="UnknownError"
        if [[ -f "$work_dir/probe.json" ]] && jq -e --arg outcome "$outcome" \
            '.outcome == $outcome and (.errorCode | type == "string")' "$work_dir/probe.json" >/dev/null; then
            error_code="$(jq -er '.errorCode | select(type == "string")' "$work_dir/probe.json")" || status=1
        else
            status=1; outcome="probe_error"
        fi
        attempt_records="$(jq -c --arg region "$location" --arg size "$size" --arg skuName "$postgres_sku" \
            --arg tier "$postgres_tier" --arg outcome "$outcome" --arg errorCode "$error_code" \
            --argjson durationSeconds "$duration" \
            '. + [{region: $region, size: $size, skuName: $skuName, tier: $tier,
                   outcome: $outcome, errorCode: $errorCode, durationSeconds: $durationSeconds}]' <<<"$attempt_records")"
        echo "==> $location/$size ($postgres_sku): $outcome, code=$error_code, ${duration}s" >&2
        # Cleanup failure and other provider errors must not be hidden by a deadline.
        if ((status != 0 && status != 2 && status != 3)); then selection_status="probe_error"; break 2; fi
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
if [[ "$selection_status" != "selected" ]]; then
    echo "::error::PostgreSQL selection: $selection_status. No PostgreSQL tuple was selected; $selected_location is for unrelated tests only." >&2
fi
