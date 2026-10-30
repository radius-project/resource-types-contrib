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

# =============================================================================
# Tests every runnable entry in every checked-in Recipe Pack for a platform
# group. Each pack is activated before its entries are deployed.
#
# Temporarily excluded entries are reported as explicit skips. Any other entry
# without test/app.bicep fails so nightly cannot silently lose coverage.
#
# Usage: ./test-all-recipe-pack-entries.sh <platform-group> [workspace] [environment]
# Example: ./test-all-recipe-pack-entries.sh azure default default
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-recipe-packs.sh
source "$SCRIPT_DIR/lib-recipe-packs.sh"
# shellcheck source=.github/scripts/lib-azure-postgres-test.sh
source "$SCRIPT_DIR/lib-azure-postgres-test.sh"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <platform-group> [workspace] [environment]" >&2
    exit 1
fi

platform_group="$1"
workspace_name="${2:-default}"
environment_name="${3:-default}"

pack_list="$(rtc_recipe_packs_for_platform_group "$platform_group")"
if [[ "$platform_group" == azure && -n "${RTC_AZURE_SELECTION_FILE+x}" ]]; then
    # Use the shared PostgreSQL deadline before unrelated cloud deployments.
    pack_list="$(awk '$0 == "azure-aks" {print; next}
        {rest = rest $0 ORS} END {printf "%s", rest}' <<<"$pack_list")"
fi
packs=()
if [[ -n "$pack_list" ]]; then
    mapfile -t packs <<<"$pack_list"
fi

if [[ ${#packs[@]} -eq 0 ]]; then
    echo "Error: no checked-in Recipe Packs target platform group '$platform_group'." >&2
    exit 1
fi

failures=0
tested=0
skipped=0
empty_packs=0

skip_reason() {
    case "$1" in
        Compute/containerImages)
            echo "requires a registry-backed test application; tracked by #398"
            ;;
        *)
            return 1
            ;;
    esac
}

# Checks a cloud dependency immediately before its entry deploys, so a known
# provider capacity limit is reported as such instead of as a recipe failure.
preflight() {
    postgres_test_size=S
    postgres_deadline=""
    case "$platform_group:$1" in
        azure:Data/postgreSqlDatabases)
            rtc_validate_postgres_test_pack "$template" || return 1
            local location selection_status
            local -a subscription_args=()
            [[ -z "${AZURE_SUBSCRIPTION_ID:-}" ]] || subscription_args=(--subscription "$AZURE_SUBSCRIPTION_ID")
            if [[ -z "${AZURE_RESOURCE_GROUP:-}" ]] ||
                ! location=$(timeout --kill-after=5s 30s az group show --name "$AZURE_RESOURCE_GROUP" \
                    "${subscription_args[@]}" --query location --output tsv) ||
                [[ ! "$location" =~ ^[a-z0-9]+$ ]]; then
                echo "Error: PostgreSQL selection requires the existing resource group's region." >&2
                return 1
            fi
            postgres_deadline=$(( $(date +%s) + 1800 ))
            if [[ -n "${RTC_AZURE_SELECTION_FILE+x}" ]]; then
                if [[ ! -f "$RTC_AZURE_SELECTION_FILE" ]] || ! jq -e '
                    type == "object" and .version == 1 and
                    (.status == "selected" or .status == "capacity_exhausted" or
                     .status == "probe_error" or .status == "deadline_exceeded") and
                    (if has("deadlineEpochSeconds") then
                        (.deadlineEpochSeconds | type == "number" and floor == . and . > 0 and . < 100000000000)
                     else true end) and
                    (if .status == "selected" then
                        (.postgres.size == "S" or .postgres.size == "M") and
                        (.location | type == "string")
                     else true end)
                ' "$RTC_AZURE_SELECTION_FILE" >/dev/null 2>&1; then
                    echo "Error: PostgreSQL selection file is missing or malformed." >&2
                    return 1
                fi
                selection_status=$(jq -r '.status' "$RTC_AZURE_SELECTION_FILE")
                if [[ "$selection_status" != selected ]]; then
                    echo "Error: PostgreSQL capacity selection failed: $selection_status." >&2
                    return 1
                fi
                if [[ "$(jq -r '.location' "$RTC_AZURE_SELECTION_FILE")" != "$location" ]]; then
                    echo "Error: PostgreSQL selection region differs from the existing resource group." >&2
                    return 1
                fi
                postgres_test_size=$(jq -r '.postgres.size' "$RTC_AZURE_SELECTION_FILE")
                rtc_postgres_test_tuple "$postgres_test_size" || return 1
                if ! jq -e --arg sku "$postgres_sku" --arg tier "$postgres_tier" \
                    '.postgres.skuName == $sku and .postgres.tier == $tier' "$RTC_AZURE_SELECTION_FILE" >/dev/null; then
                    echo "Error: PostgreSQL selection size does not match the approved SKU and tier." >&2
                    return 1
                fi
                postgres_deadline=$(jq -r --argjson fallback "$postgres_deadline" \
                    '.deadlineEpochSeconds // $fallback' "$RTC_AZURE_SELECTION_FILE")
                if ((postgres_deadline <= $(date +%s))); then
                    echo "Error: PostgreSQL selection deadline has expired." >&2
                    return 1
                fi
            else
                # Never relocate an existing group or repeat the full region search.
                AZURE_LOCATION="$location" RTC_POSTGRES_TEST_SIZE=S \
                    RTC_POSTGRES_PROBE_ATTEMPTS=1 RTC_POSTGRES_PROBE_WAIT_SECONDS=0 \
                    RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=900 \
                    "$SCRIPT_DIR/probe-azure-postgres-capacity.sh" || return 1
            fi
            ;;
    esac
}

for pack_id in "${packs[@]}"; do
    resource_types="$(rtc_list_recipe_pack_types "$pack_id")"
    if [[ "$platform_group" == azure && -n "${RTC_AZURE_SELECTION_FILE+x}" ]]; then
        resource_types="$(awk '$0 == "Data/postgreSqlDatabases" {print; next}
            {rest = rest $0 ORS} END {printf "%s", rest}' <<<"$resource_types")"
    fi
    template="$(rtc_recipe_pack_template "$pack_id")"
    pack_name="$(rtc_recipe_pack_name "$template")"
    if [[ -z "$pack_name" ]]; then
        echo "Error: could not determine the Recipe Pack name in $template." >&2
        exit 1
    fi

    rad env update "$environment_name" --workspace "$workspace_name" --recipe-packs "$pack_name"
    pack_tested=0

    while IFS= read -r resource_type_dir; do
        [[ -z "$resource_type_dir" ]] && continue
        if reason="$(skip_reason "$resource_type_dir")"; then
            echo "==> SKIPPED: $resource_type_dir from pack '$pack_id': $reason"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ ! -f "$resource_type_dir/test/app.bicep" ]]; then
            echo "==> FAILED: $resource_type_dir from pack '$pack_id' has no test/app.bicep" >&2
            failures=$((failures + 1))
            continue
        fi

        tested=$((tested + 1))
        pack_tested=$((pack_tested + 1))

        test_args=("$resource_type_dir" "$workspace_name" "$environment_name")
        if [[ "$resource_type_dir" == "Data/mySqlDatabases" ]]; then
            mysql_test_mode="connection-only"
            if rtc_recipe_pack_verifies_mysql_transport "$pack_id"; then
                mysql_test_mode="verify-transport"
            fi
            test_args+=("$mysql_test_mode")
        fi

        echo "=============================================================="
        echo "==> Recipe Pack entry test: $resource_type_dir (from pack '$pack_id')"
        echo "=============================================================="
        if ! preflight "$resource_type_dir"; then
            echo "==> FAILED: $resource_type_dir (from pack '$pack_id'): preflight check failed" >&2
            failures=$((failures + 1))
            continue
        fi
        if ! RTC_TEST_PLATFORM="$platform_group" RTC_POSTGRES_TEST_SIZE="$postgres_test_size" \
            RTC_POSTGRES_TEST_DEADLINE_EPOCH="$postgres_deadline" \
            "$SCRIPT_DIR/test-recipe-pack-entry.sh" "${test_args[@]}"; then
            echo "==> FAILED: $resource_type_dir (from pack '$pack_id')" >&2
            failures=$((failures + 1))
        fi
    done <<<"$resource_types"

    if [[ "$pack_tested" -eq 0 ]]; then
        echo "Error: Recipe Pack '$pack_id' has no entries with test applications." >&2
        empty_packs=$((empty_packs + 1))
    fi
done

echo "=============================================================="
echo "==> Recipe Pack entry tests complete: $tested tested, $skipped skipped, $failures failed"
echo "=============================================================="

[[ "$tested" -gt 0 && "$failures" -eq 0 && "$empty_packs" -eq 0 ]]
