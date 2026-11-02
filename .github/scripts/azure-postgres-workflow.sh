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
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

validate_run_context() {
    run_id="${GITHUB_RUN_ID:-}"
    run_attempt="${GITHUB_RUN_ATTEMPT:-}"
    [[ "$run_id" =~ ^[0-9]+$ && "$run_attempt" =~ ^[1-9][0-9]{0,8}$ ]] ||
        { echo "Error: invalid workflow run ownership context." >&2; return 1; }
}

run_bounded_azure_command() {
    local requested_limit="$1" remaining command_pid status=0
    shift
    if [[ -v cleanup_deadline ]]; then
        remaining=$((cleanup_deadline - SECONDS))
        ((remaining > 0)) || return 124
        if ((requested_limit > remaining)); then requested_limit="$remaining"; fi
    fi
    python3 "$script_dir/run-bounded-command.py" "$requested_limit" "$@" &
    command_pid=$!
    trap 'kill -TERM "$command_pid" 2>/dev/null || true; wait "$command_pid" 2>/dev/null || true; exit 143' TERM
    trap 'kill -INT "$command_pid" 2>/dev/null || true; wait "$command_pid" 2>/dev/null || true; exit 130' INT
    wait "$command_pid" || status=$?
    trap - INT TERM
    return "$status"
}

validate_probe_group() {
    local group="$1" group_attempt
    probe_owner_token=""
    if [[ "$group" =~ ^rrttest-nightly-${run_id}-([1-9][0-9]{0,8})-probe(-([a-f0-9]{32}))?$ ]] ||
        [[ "$group" =~ ^rrttest-rc-${run_id}-([1-9][0-9]{0,8})-probe(-([a-f0-9]{32}))?$ ]]; then
        group_attempt="${BASH_REMATCH[1]}"
        probe_owner_token="${BASH_REMATCH[3]:-}"
    else
        echo "Error: refusing to delete a probe group not owned by this run." >&2
        return 1
    fi
    if [[ ! "$group_attempt" =~ ^[1-9][0-9]{0,8}$ ]] ||
        ((10#$group_attempt > 10#$run_attempt)); then
        echo "Error: refusing a probe group from a future or invalid run attempt." >&2
        return 1
    fi
}

resource_group_has_owner_tag() {
    local group="$1" tag_name="$2" tag_value="$3" actual
    [[ "$tag_value" =~ ^[a-f0-9]{32}$ ]] || {
        echo "Error: no verifiable ownership token for resource group '$group'; refusing deletion." >&2
        return 1
    }
    actual="$(run_bounded_azure_command 30 az group show --name "$group" \
        --subscription "$AZURE_SUBSCRIPTION_ID" --query "tags.${tag_name}" --output tsv)" || {
        echo "Error: could not verify ownership of resource group '$group'." >&2
        return 1
    }
    [[ "$actual" == "$tag_value" ]] || {
        echo "Error: resource group '$group' has no matching $tag_name ownership tag; refusing deletion." >&2
        return 1
    }
}

delete_and_confirm_resource_group() {
    local group="$1" owner_tag="$2" owner_token="$3" exists
    exists="$(run_bounded_azure_command 30 az group exists --name "$group" \
        --subscription "$AZURE_SUBSCRIPTION_ID" --output tsv)" || return 1
    if [[ "$exists" == false ]]; then return 0; fi
    [[ "$exists" == true ]] ||
        { echo "Error: could not determine resource group state for '$group'." >&2; return 1; }
    resource_group_has_owner_tag "$group" "$owner_tag" "$owner_token" || return 1
    run_bounded_azure_command 840 az group delete --name "$group" \
        --subscription "$AZURE_SUBSCRIPTION_ID" --yes --only-show-errors --output none || return 1
    exists="$(run_bounded_azure_command 30 az group exists --name "$group" \
        --subscription "$AZURE_SUBSCRIPTION_ID" --output tsv)" || return 1
    [[ "$exists" == false ]] ||
        { echo "Error: resource group deletion was not confirmed for '$group'." >&2; return 1; }
    echo "Resource group deletion confirmed: $group"
}

cleanup_probe_group() {
    local group="$1"
    validate_probe_group "$group" || return 1
    delete_and_confirm_resource_group "$group" rtcPostgresSelectorOwner "$probe_owner_token"
}

create_main_group() {
    local kind="$1" group="$2" location="$3" owner_token="$4" expected_group existing deadline
    [[ "$kind" == nightly || "$kind" == rc ]] || {
        echo "Error: main resource group kind must be nightly or rc." >&2
        return 1
    }
    [[ "$owner_token" =~ ^[a-f0-9]{32}$ ]] || {
        echo "Error: invalid main resource group ownership token." >&2
        return 1
    }
    expected_group="rrttest-${kind}-${run_id}-${run_attempt}-${owner_token}"
    [[ "$group" == "$expected_group" ]] || {
        echo "Error: refusing unexpected main resource group name '$group'." >&2
        return 1
    }
    existing="$(run_bounded_azure_command 30 az group exists --name "$group" \
        --subscription "$AZURE_SUBSCRIPTION_ID" --output tsv)" || {
        echo "Error: could not verify main resource group '$group'; refusing to create or delete it." >&2
        return 1
    }
    [[ "$existing" == false ]] || {
        echo "Error: main resource group '$group' is not confirmed absent; refusing to update or delete it." >&2
        return 1
    }
    echo "Creating main resource group '$group' with rtcAzureTestGroupOwner=$owner_token." >&2
    if ! run_bounded_azure_command 180 az group create --only-show-errors --output none \
        --location "$location" --name "$group" --subscription "$AZURE_SUBSCRIPTION_ID" \
        --tags "creationTime=$(date +%s)" "rtcRunId=$run_id" "rtcRunAttempt=$run_attempt" \
        "rtcAzureTestGroupOwner=$owner_token"; then
        echo "Error: main resource group creation failed or timed out for '$group'." >&2
        if resource_group_has_owner_tag "$group" rtcAzureTestGroupOwner "$owner_token"; then
            echo "The owned partial group will be handled by the run cleanup job." >&2
        else
            echo "Ownership could not be proven; it will not be deleted. Inspect '$group' and its ownership tag." >&2
        fi
        return 1
    fi
    resource_group_has_owner_tag "$group" rtcAzureTestGroupOwner "$owner_token" || {
        echo "Error: main resource group creation succeeded but ownership could not be confirmed; refusing further use." >&2
        return 1
    }
    deadline=$((SECONDS + 60))
    while :; do
        existing="$(run_bounded_azure_command 10 az group exists --name "$group" \
            --subscription "$AZURE_SUBSCRIPTION_ID" --output tsv)" || return 1
        [[ "$existing" == true ]] && break
        if [[ "$existing" != false ]] || ((SECONDS >= deadline)); then
            echo "Error: main resource group '$group' did not become ready in time." >&2
            return 1
        fi
        echo "Waiting for resource group '$group' to be available..." >&2
        sleep 5
    done
    echo "Resource group '$group' is ready"
}

fallback_location() {
    local override="${REGION_OVERRIDE:-${RTC_AZURE_TEST_REGIONS:-}}"
    if [[ "$override" =~ ^[a-z0-9]+(,[a-z0-9]+)*$ ]]; then
        printf '%s\n' "${override%%,*}"
    elif [[ "${AZURE_LOCATION:-}" =~ ^[a-z0-9]+$ ]]; then
        printf '%s\n' "$AZURE_LOCATION"
    elif [[ "${AZURE_FALLBACK_LOCATION:-}" =~ ^[a-z0-9]+$ ]]; then
        printf '%s\n' "$AZURE_FALLBACK_LOCATION"
    else
        printf '%s\n' centralus
    fi
}

write_failed_selection() {
    local location="$1" deadline="$2" temporary
    temporary="$(mktemp "${RTC_AZURE_SELECTION_FILE}.XXXXXX")" || return 1
    if [[ -f "$RTC_AZURE_SELECTION_FILE" ]] && jq -e '
        type == "object" and .version == 1 and
        (.status == "selected" or .status == "capacity_exhausted" or
         .status == "unsupported" or .status == "probe_error" or
         .status == "deadline_exceeded") and
        (.location | type == "string") and (.attempts | type == "array") and
        (.attempts | all(.[]; (.region | type == "string") and (.size | type == "string") and
            (.skuName | type == "string") and (.tier | type == "string") and
            (.outcome | type == "string") and (.errorCode | type == "string") and
            (.durationSeconds | type == "number")))
    ' "$RTC_AZURE_SELECTION_FILE" >/dev/null 2>&1; then
        jq --arg location "$location" --argjson fallbackDeadline "$deadline" '
            .status = (if .status == "unsupported" then "unsupported" else "probe_error" end) |
            .location = $location |
            .deadlineEpochSeconds =
                (if (.deadlineEpochSeconds | type == "number" and floor == . and . > 0 and . < 100000000000)
                 then .deadlineEpochSeconds else $fallbackDeadline end) |
            del(.postgres)
        ' "$RTC_AZURE_SELECTION_FILE" >"$temporary" || {
            rm -f -- "$temporary"
            return 1
        }
    else
        jq -n --arg location "$location" --argjson deadline "$deadline" \
            '{version:1,status:"probe_error",location:$location,attempts:[],
              deadlineEpochSeconds:$deadline}' >"$temporary" || {
            rm -f -- "$temporary"
            return 1
        }
    fi
    mv -f -- "$temporary" "$RTC_AZURE_SELECTION_FILE"
}

select_context() {
    local probe_group="$1" regions location fallback deadline selector_status deadline_seconds
    local size_list size
    local -a sizes normalized_sizes
    : "${RTC_AZURE_SELECTION_FILE:?selection file is required}"
    : "${GITHUB_ENV:?workflow environment file is required}"
    fallback="$(fallback_location)"
    mkdir -p "$(dirname "$RTC_AZURE_SELECTION_FILE")"
    rm -f -- "$RTC_AZURE_SELECTION_FILE"
    deadline_seconds="${RTC_POSTGRES_SELECTION_DEADLINE_SECONDS:-3600}"
    if [[ ! "$deadline_seconds" =~ ^[1-9][0-9]{0,3}$ ]] || ((deadline_seconds > 3600)); then
        deadline_seconds=3600
    fi
    deadline=$(( $(date +%s) + deadline_seconds ))
    size_list="${RTC_POSTGRES_TEST_SIZES-S,M}"
    if [[ ! "$size_list" =~ ^[SM](,[SM])*$ ]]; then
        printf 'AZURE_LOCATION=%s\n' "$fallback" >>"$GITHUB_ENV"
        write_failed_selection "$fallback" "$deadline" || return 1
        echo "::error::Azure PostgreSQL size configuration is invalid; continuing unrelated entries in $fallback without PostgreSQL allocation."
        return 1
    fi
    normalized_sizes=()
    IFS=',' read -r -a sizes <<<"$size_list"
    for size in "${sizes[@]}"; do
        if [[ ! " ${normalized_sizes[*]} " == *" $size "* ]]; then
            normalized_sizes+=("$size")
        fi
    done
    size_list="$(IFS=','; echo "${normalized_sizes[*]}")"
    export RTC_POSTGRES_TEST_SIZES="$size_list"
    printf 'RTC_POSTGRES_TEST_SIZES=%s\n' "$size_list" >>"$GITHUB_ENV"
    if [[ -n "${REGION_OVERRIDE:-}" ]]; then
        export RTC_AZURE_TEST_REGIONS="$REGION_OVERRIDE"
    fi
    if regions="$(bash "$script_dir/azure-postgres-workflow.sh" regions)"; then
        fallback="${regions%%,*}"
        export RTC_AZURE_TEST_REGIONS="$regions"
    else
        regions="$fallback"
        export RTC_AZURE_TEST_REGIONS="$regions"
        printf 'AZURE_LOCATION=%s\n' "$fallback" >>"$GITHUB_ENV"
        write_failed_selection "$fallback" "$deadline" || return 1
        echo "::error::Azure PostgreSQL region configuration is invalid; continuing unrelated entries in $fallback without PostgreSQL allocation."
        return 1
    fi
    if location="$(bash "$script_dir/select-azure-test-location.sh" "$probe_group")" &&
        [[ "$location" =~ ^[a-z0-9]+$ && ",$regions," == *",$location,"* ]] &&
        [[ -f "$RTC_AZURE_SELECTION_FILE" ]] && jq -e '
            type == "object" and .version == 1 and
            (.status == "selected" or .status == "capacity_exhausted" or
             .status == "unsupported" or .status == "probe_error" or
             .status == "deadline_exceeded") and
            (.location | type == "string") and (.attempts | type == "array")
        ' "$RTC_AZURE_SELECTION_FILE" >/dev/null 2>&1; then
        printf 'AZURE_LOCATION=%s\n' "$location" >>"$GITHUB_ENV"
        return 0
    else
        selector_status=$?
    fi
    printf 'AZURE_LOCATION=%s\n' "$fallback" >>"$GITHUB_ENV"
    write_failed_selection "$fallback" "$deadline" || {
        echo "::error::Azure PostgreSQL selection failed and its failure record could not be written."
        return 1
    }
    echo "::error::Azure PostgreSQL capacity selection failed (status $selector_status); continuing unrelated entries in $fallback without PostgreSQL allocation."
    return 1
}

case "${1:-}" in
    select-context)
        probe_group="${2:-}"
        [[ -n "$probe_group" ]] || { echo "Error: probe resource group is required." >&2; exit 1; }
        select_context "$probe_group"
        ;;
    regions)
        if [[ -v RTC_AZURE_TEST_REGIONS ]]; then
            list="$RTC_AZURE_TEST_REGIONS"
        else
            regions=("${AZURE_LOCATION:-westus3}" "${AZURE_FALLBACK_LOCATION:-centralus}" \
                westus3 centralus northcentralus southcentralus)
            list="$(IFS=','; echo "${regions[*]}")"
        fi
        [[ "$list" =~ ^[a-z0-9]+(,[a-z0-9]+)*$ ]] ||
            { echo "Error: invalid Azure region list." >&2; exit 1; }
        IFS=',' read -r -a regions <<<"$list"
        ((${#regions[@]} <= 32)) ||
            { echo "Error: too many region entries." >&2; exit 1; }
        candidates=()
        for region in "${regions[@]}"; do
            if [[ ! " ${candidates[*]} " == *" $region "* ]]; then candidates+=("$region"); fi
        done
        if [[ ! -v RTC_AZURE_TEST_REGIONS ]] && ((${#candidates[@]} > 4)); then
            candidates=("${candidates[@]:0:4}")
        fi
        ((${#candidates[@]} <= 4)) ||
            { echo "Error: at most four distinct regions are allowed." >&2; exit 1; }
        (IFS=','; echo "${candidates[*]}")
        ;;
    summary)
        : "${RTC_AZURE_SELECTION_FILE:?selection file is required}"
        : "${GITHUB_STEP_SUMMARY:?summary path is required}"
        if [[ ! -f "$RTC_AZURE_SELECTION_FILE" ]]; then
            echo 'PostgreSQL selection: no result (selection did not complete).' >>"$GITHUB_STEP_SUMMARY"
            echo "Error: PostgreSQL selection result is missing." >&2
            exit 1
        fi
        # Render only the safe contract fields, never raw JSON or provider output.
        jq -er '
            if .version != 1 or (.attempts | type) != "array" or
                (.status != "selected" and .status != "capacity_exhausted" and
                 .status != "unsupported" and .status != "probe_error" and
                 .status != "deadline_exceeded") then
                error("invalid selection record")
            else . end |
            def cell: tostring | gsub("[^A-Za-z0-9_., -]"; "?");
            "## PostgreSQL capacity selection\n",
            ("Final selection status: **" + (.status | cell) + "**\n"),
            ("Shared work deadline (Unix seconds): " + (.deadlineEpochSeconds | cell) + "\n"),
            "| Region | Size | SKU | Tier | Outcome | Error code | Duration (s) |",
            "| --- | --- | --- | --- | --- | --- | --- |",
            (.attempts[] | "| " + ([.region,.size,.skuName,.tier,.outcome,.errorCode,.durationSeconds]
                | map(cell) | join(" | ")) + " |")
        ' "$RTC_AZURE_SELECTION_FILE" >>"$GITHUB_STEP_SUMMARY"
        ;;
    cleanup-probe)
        group="${2:-}"
        [[ -n "$group" ]] || { echo "No probe group recorded; nothing to delete."; exit 0; }
        validate_run_context
        : "${AZURE_SUBSCRIPTION_ID:?subscription is required}"
        cleanup_probe_group "$group"
        ;;
    create-main)
        kind="${2:-}" group="${3:-}" location="${4:-}" owner_token="${5:-}"
        validate_run_context
        : "${AZURE_SUBSCRIPTION_ID:?subscription is required}"
        [[ -n "$location" ]] || { echo "Error: resource group location is required." >&2; exit 1; }
        create_main_group "$kind" "$group" "$location" "$owner_token"
        ;;
    cleanup-run-groups)
        kind="${2:-}"
        [[ "$kind" == nightly || "$kind" == rc ]] ||
            { echo "Error: cleanup kind must be nightly or rc." >&2; exit 1; }
        validate_run_context
        : "${AZURE_SUBSCRIPTION_ID:?subscription is required}"
        prefix="rrttest-${kind}-${run_id}-"
        cleanup_deadline=$((SECONDS + 1500))
        if ! groups="$(run_bounded_azure_command 30 az group list --query '[].name' \
            --subscription "$AZURE_SUBSCRIPTION_ID" --output tsv)"; then
            echo "Error: could not list Azure resource groups for this run." >&2
            exit 1
        fi
        cleanup_status=0
        while IFS= read -r group; do
            [[ "$group" == "$prefix"* ]] || continue
            suffix="${group#"$prefix"}"
            is_probe=false
            owner_tag=""
            owner_token=""
            if [[ "$suffix" =~ ^([1-9][0-9]{0,8})-probe-([a-f0-9]{32})$ ]]; then
                is_probe=true
                group_attempt="${BASH_REMATCH[1]}"
                owner_token="${BASH_REMATCH[2]}"
                owner_tag="rtcPostgresSelectorOwner"
            elif [[ "$suffix" =~ ^([1-9][0-9]{0,8})-probe$ ]]; then
                is_probe=true
                group_attempt="${BASH_REMATCH[1]}"
            elif [[ "$suffix" =~ ^([1-9][0-9]{0,8})-([a-f0-9]{32})$ ]]; then
                group_attempt="${BASH_REMATCH[1]}"
                owner_token="${BASH_REMATCH[2]}"
                owner_tag="rtcAzureTestGroupOwner"
            elif [[ "$suffix" =~ ^[1-9][0-9]{0,8}$ ]]; then
                group_attempt="$suffix"
            else
                continue
            fi
            ((10#$group_attempt <= 10#$run_attempt)) || continue
            if [[ "$is_probe" == true ]]; then
                if ! cleanup_probe_group "$group"; then cleanup_status=1; fi
            else
                if ! delete_and_confirm_resource_group "$group" "$owner_tag" "$owner_token"; then
                    echo "Error: could not delete owned resource group '$group'." >&2
                    cleanup_status=1
                fi
            fi
            if ((SECONDS >= cleanup_deadline)); then
                echo "Error: owned resource-group cleanup reached its time limit." >&2
                exit 1
            fi
        done <<<"$groups"
        exit "$cleanup_status"
        ;;
    *) echo "Usage: $0 regions|select-context <probe-group>|summary|cleanup-probe [owned-group]|create-main <nightly|rc> <group> <location> <token>|cleanup-run-groups <nightly|rc>" >&2; exit 1 ;;
esac
