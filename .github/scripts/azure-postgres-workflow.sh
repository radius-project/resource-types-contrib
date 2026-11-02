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

validate_run_context() {
    run_id="${GITHUB_RUN_ID:-}"
    run_attempt="${GITHUB_RUN_ATTEMPT:-}"
    [[ "$run_id" =~ ^[0-9]+$ && "$run_attempt" =~ ^[1-9][0-9]{0,8}$ ]] ||
        { echo "Error: invalid workflow run ownership context." >&2; return 1; }
}

run_bounded_azure_command() {
    local requested_limit="$1" remaining
    shift
    if [[ -v cleanup_deadline ]]; then
        remaining=$((cleanup_deadline - SECONDS))
        ((remaining > 0)) || return 124
        if ((requested_limit > remaining)); then requested_limit="$remaining"; fi
    fi
    timeout --kill-after=5 "$requested_limit" "$@"
}

validate_probe_group() {
    local group="$1" group_attempt group_prefix
    case "$group" in
        "rrttest-nightly-${run_id}-"*-probe)
            group_prefix="rrttest-nightly-${run_id}-"
            group_attempt="${group#"$group_prefix"}"
            group_attempt="${group_attempt%-probe}"
            ;;
        "rrttest-rc-${run_id}-"*-probe)
            group_prefix="rrttest-rc-${run_id}-"
            group_attempt="${group#"$group_prefix"}"
            group_attempt="${group_attempt%-probe}"
            ;;
        *) echo "Error: refusing to delete a probe group not owned by this run." >&2; return 1 ;;
    esac
    if [[ ! "$group_attempt" =~ ^[1-9][0-9]{0,8}$ ]] ||
        ((10#$group_attempt > 10#$run_attempt)); then
        echo "Error: refusing a probe group from a future or invalid run attempt." >&2
        return 1
    fi
}

delete_and_confirm_resource_group() {
    local group="$1" exists
    exists="$(run_bounded_azure_command 30 az group exists --name "$group" \
        --subscription "$AZURE_SUBSCRIPTION_ID" --output tsv)" || return 1
    if [[ "$exists" == false ]]; then return 0; fi
    [[ "$exists" == true ]] ||
        { echo "Error: could not determine resource group state for '$group'." >&2; return 1; }
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
    delete_and_confirm_resource_group "$group"
}

case "${1:-}" in
    regions)
        if [[ -v RTC_AZURE_TEST_REGIONS ]]; then
            list="$RTC_AZURE_TEST_REGIONS"
        else
            list="${AZURE_LOCATION:-westus3},${AZURE_FALLBACK_LOCATION:-eastus2},centralus"
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
                 .status != "probe_error" and .status != "deadline_exceeded") then
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
            if [[ "$suffix" == *-probe ]]; then
                is_probe=true
                suffix="${suffix%-probe}"
            fi
            [[ "$suffix" =~ ^[1-9][0-9]{0,8}$ ]] || continue
            ((10#$suffix <= 10#$run_attempt)) || continue
            if [[ "$is_probe" == true ]]; then
                if ! cleanup_probe_group "$group"; then cleanup_status=1; fi
            else
                if ! delete_and_confirm_resource_group "$group"; then
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
    *) echo "Usage: $0 regions|summary|cleanup-probe [owned-group]|cleanup-run-groups <nightly|rc>" >&2; exit 1 ;;
esac
