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

# Usage: select-azure-test-location.sh <owned-probe-resource-group> <region>...
# RTC_POSTGRES_PROBE_OWNER_TOKEN must be the 128-bit token in the group name.
# RTC_AZURE_TEST_REGIONS, when set, overrides positional regions.
# RTC_POSTGRES_TEST_SIZES defaults to S,M. Sizes are the outer loop.
# The selector deletes the complete owned group after the search. Killing Azure
# CLI does not cancel an Azure provider request; a late create remains confined
# to this group and the caller's unconditional cleanup job retries deletion.

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-azure-postgres-test.sh
source "$script_dir/lib-azure-postgres-test.sh"

if (($# < 1)); then
    echo "Usage: $0 <owned-probe-resource-group> <region>..." >&2
    exit 1
fi
probe_rg="$1"
shift
probe_owner_token="${RTC_POSTGRES_PROBE_OWNER_TOKEN:-}"
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
create_timeout="${RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS-900}"
delete_timeout="${RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS-900}"
selection_timeout="${RTC_POSTGRES_PREFLIGHT_TIMEOUT_SECONDS-3300}"
if [[ ! "$probe_rg" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    ((${#probe_rg} > 90)) || [[ ! "$probe_owner_token" =~ ^[a-f0-9]{32}$ ]] ||
    ((${#regions[@]} == 0 || ${#regions[@]} > 32 || ${#sizes[@]} == 0 || ${#sizes[@]} > 32)) ||
    ! rtc_postgres_positive_limit "$create_timeout" 900 ||
    ! rtc_postgres_positive_limit "$delete_timeout" 900 ||
    ! rtc_postgres_positive_limit "$selection_timeout" 3300; then
    echo "Error: invalid selection candidates, ownership token, or time limits." >&2
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
if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
    subscription_args=(--subscription "$AZURE_SUBSCRIPTION_ID")
fi
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/rtc-postgres-selection-XXXXXX")"
selection_status="probe_error"
selected_location="${candidates[0]}"
selected_postgres="null"
attempt_records="[]"
group_owned=false
selection_deadline=$((SECONDS + selection_timeout))

group_has_owner_tag() {
    local owner_tag
    owner_tag="$(timeout --signal=KILL 30 az group show "${subscription_args[@]}" \
        --name "$probe_rg" --query "tags.rtcPostgresSelectorOwner" --output tsv 2>/dev/null)" ||
        return 1
    [[ "$owner_tag" == "$probe_owner_token" ]]
}

delete_owned_probe_group() {
    local exists
    exists="$(timeout --signal=KILL 30 az group exists "${subscription_args[@]}" \
        --name "$probe_rg" --output tsv)" || return 1
    [[ "$exists" == false ]] && return 0
    [[ "$exists" == true ]] || return 1
    group_has_owner_tag || return 1
    timeout --signal=KILL "$delete_timeout" az group delete "${subscription_args[@]}" \
        --name "$probe_rg" --yes --only-show-errors --output none >&2 || return 1
    exists="$(timeout --signal=KILL 30 az group exists "${subscription_args[@]}" \
        --name "$probe_rg" --output tsv)" || return 1
    [[ "$exists" == false ]]
}

# shellcheck disable=SC2329
finish() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "$group_owned" == true ]] && ! delete_owned_probe_group; then
        echo "Error: owned probe group '$probe_rg' cleanup was not confirmed." >&2
        selection_status="probe_error"
        selected_postgres="null"
        selected_location="${candidates[0]}"
        status=1
    fi
    if [[ -n "${RTC_AZURE_SELECTION_FILE:-}" ]]; then
        jq -n --arg status "$selection_status" --arg location "$selected_location" \
            --arg probeResourceGroup "$probe_rg" --argjson postgres "$selected_postgres" \
            --argjson attempts "$attempt_records" \
            '{version:1,status:$status,location:$location,
              probeResourceGroup:$probeResourceGroup,attempts:$attempts}
             + (if $status == "selected" then {postgres:$postgres} else {} end)' \
            >"$RTC_AZURE_SELECTION_FILE" || status=1
    fi
    rm -rf -- "$work_dir"
    printf '%s\n' "$selected_location"
    exit "$status"
}
trap finish EXIT
trap 'exit 1' INT TERM

existing_group="$(timeout --signal=KILL 30 az group exists "${subscription_args[@]}" \
    --name "$probe_rg" --output tsv)" || {
    echo "Error: could not verify probe group '$probe_rg'." >&2
    exit 1
}
[[ "$existing_group" == false ]] || {
    echo "Error: probe group '$probe_rg' is not confirmed absent; refusing to update it." >&2
    exit 1
}

group_create_limit=$((selection_deadline - SECONDS))
if ((group_create_limit > 180)); then group_create_limit=180; fi
if ((group_create_limit <= 0)) ||
    ! timeout --signal=KILL "$group_create_limit" az group create "${subscription_args[@]}" \
    --name "$probe_rg" --location "${candidates[0]}" \
    --tags "creationTime=$(date +%s)" "rtcRunId=${GITHUB_RUN_ID:-local}" \
    "rtcRunAttempt=${GITHUB_RUN_ATTEMPT:-local}" \
    "rtcPostgresSelectorOwner=$probe_owner_token" \
    --only-show-errors --output none >&2; then
    echo "Error: probe group creation failed or timed out for '$probe_rg'." >&2
    if group_has_owner_tag; then
        group_owned=true
    else
        echo "The workflow cleanup job will retry the exact owned group after the Azure request settles." >&2
    fi
    exit 1
fi
group_has_owner_tag || {
    echo "Error: probe group ownership could not be confirmed." >&2
    exit 1
}
group_owned=true

selection_status="capacity_exhausted"
for size in "${test_sizes[@]}"; do
    rtc_postgres_test_tuple "$size"
    for location in "${candidates[@]}"; do
        remaining=$((selection_deadline - SECONDS))
        if ((remaining <= 0)); then
            echo "Error: PostgreSQL preflight deadline expired." >&2
            selection_status="probe_error"
            break 2
        fi
        candidate_timeout="$create_timeout"
        if ((candidate_timeout > remaining)); then candidate_timeout="$remaining"; fi
        started=$SECONDS
        status=0
        rm -f -- "$work_dir/probe.json"
        AZURE_RESOURCE_GROUP="$probe_rg" AZURE_LOCATION="$location" RTC_POSTGRES_TEST_SIZE="$size" \
            RTC_POSTGRES_PROBE_ATTEMPTS=1 RTC_POSTGRES_PROBE_WAIT_SECONDS=0 \
            RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS="$candidate_timeout" \
            RTC_POSTGRES_PROBE_GROUP_LIFECYCLE=true \
            RTC_POSTGRES_PROBE_RESULT_FILE="$work_dir/probe.json" \
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
        if [[ -f "$work_dir/probe.json" ]] && jq -e --arg outcome "$outcome" '
            .outcome == $outcome and
            (.errorCode | type == "string" and test("^$|^[A-Za-z][A-Za-z0-9]*$"))
        ' "$work_dir/probe.json" >/dev/null; then
            error_code="$(jq -r '.errorCode' "$work_dir/probe.json")"
        else
            status=1
            outcome="probe_error"
        fi
        attempt_records="$(jq -c --arg region "$location" --arg size "$size" \
            --arg skuName "$postgres_sku" --arg tier "$postgres_tier" \
            --arg outcome "$outcome" --arg errorCode "$error_code" \
            --argjson durationSeconds "$duration" '
            . + [{region:$region,size:$size,skuName:$skuName,tier:$tier,
                  outcome:$outcome,errorCode:$errorCode,
                  durationSeconds:$durationSeconds,cleanup:"not_required"}]
        ' <<<"$attempt_records")"
        echo "==> $location/$size ($postgres_sku): $outcome, code=$error_code, ${duration}s" >&2
        case "$status" in
            0)
                selection_status="selected"
                selected_location="$location"
                selected_postgres="$(jq -n --arg size "$size" --arg skuName "$postgres_sku" \
                    --arg tier "$postgres_tier" '{size:$size,skuName:$skuName,tier:$tier}')"
                break 2
                ;;
            2|4|5) ;;
            *)
                selection_status="probe_error"
                break 2
                ;;
        esac
    done
done

if [[ "$selection_status" == capacity_exhausted ]] &&
    ! jq -e 'any(.[]; .outcome == "capacity_exhausted")' <<<"$attempt_records" >/dev/null; then
    if jq -e 'all(.[]; .outcome == "unsupported")' <<<"$attempt_records" >/dev/null; then
        selection_status="unsupported"
    elif jq -e 'all(.[]; .outcome == "restricted")' <<<"$attempt_records" >/dev/null; then
        selection_status="restricted"
    else
        selection_status="catalog_unavailable"
    fi
fi
if [[ "$selection_status" != selected ]]; then
    echo "::warning::PostgreSQL selection: $selection_status. Unrelated Azure tests can use $selected_location." >&2
fi
if [[ "$selection_status" == probe_error ]]; then
    exit 1
fi
