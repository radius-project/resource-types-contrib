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

case "${1:-}" in
    regions)
        if [[ -v RTC_AZURE_TEST_REGIONS ]]; then
            list="$RTC_AZURE_TEST_REGIONS"
        else
            list="${AZURE_LOCATION:-westus3},${AZURE_FALLBACK_LOCATION:-eastus2},centralus,westus2"
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
        case "$group" in
            "rrttest-nightly-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}-probe" | \
            "rrttest-rc-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-probe") ;;
            *) echo "Error: refusing to delete a probe group not owned by this run." >&2; exit 1 ;;
        esac
        : "${AZURE_SUBSCRIPTION_ID:?subscription is required}"
        exists="$(timeout --kill-after=5 30 az group exists --name "$group" \
            --subscription "$AZURE_SUBSCRIPTION_ID" --output tsv)"
        if [[ "$exists" == false ]]; then exit 0; fi
        [[ "$exists" == true ]] || { echo "Error: could not determine probe group state." >&2; exit 1; }
        timeout --kill-after=5 840 az group delete --name "$group" \
            --subscription "$AZURE_SUBSCRIPTION_ID" --yes --only-show-errors --output none
        exists="$(timeout --kill-after=5 30 az group exists --name "$group" \
            --subscription "$AZURE_SUBSCRIPTION_ID" --output tsv)"
        [[ "$exists" == false ]] ||
            { echo "Error: probe group deletion was not confirmed." >&2; exit 1; }
        echo "Probe group deletion confirmed: $group"
        ;;
    *) echo "Usage: $0 regions|summary|cleanup-probe [owned-group]" >&2; exit 1 ;;
esac
