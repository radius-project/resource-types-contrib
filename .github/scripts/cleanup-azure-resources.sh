#!/bin/bash

# ------------------------------------------------------------
# Copyright 2025 The Radius Authors.
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
# Cleanup script for Azure resources created during recipe validation.
# 1. Deletes the resource group of the current test run (AZURE_RESOURCE_GROUP).
# 2. Best-effort sweep of resources that earlier test runs left behind:
#    - Deletes stale "rrttest-*" resource groups whose creationTime tag is
#      older than AZURE_CLEANUP_MAX_AGE_HOURS (default: 12).
#    - Purges soft-deleted Key Vaults that were in "rrttest-*" resource groups.
#      Soft-deleted vaults keep their names reserved and stay in the
#      subscription for the retention period (up to 90 days).
# Set AZURE_CLEANUP_SWEEP=false to skip the sweep. Sweep errors do not fail
# the script.
# =============================================================================

set -euo pipefail

AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
AZURE_CLEANUP_SWEEP="${AZURE_CLEANUP_SWEEP:-true}"
AZURE_CLEANUP_MAX_AGE_HOURS="${AZURE_CLEANUP_MAX_AGE_HOURS:-12}"
TEST_RG_PREFIX="rrttest-"

if [[ -z "$AZURE_RESOURCE_GROUP" ]]; then
    echo "No Azure resource group provided, skipping cleanup."
    exit 0
fi

if ! command -v az >/dev/null 2>&1; then
    echo "Azure CLI not available; cannot delete resource group '$AZURE_RESOURCE_GROUP'." >&2
    exit 1
fi

SUB_ARGS=()
if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
    SUB_ARGS+=(--subscription "$AZURE_SUBSCRIPTION_ID")
fi

echo "Deleting Azure resource group '$AZURE_RESOURCE_GROUP'"
az group delete --name "$AZURE_RESOURCE_GROUP" --yes --no-wait "${SUB_ARGS[@]}"
echo "Azure cleanup initiated for resource group '$AZURE_RESOURCE_GROUP'"

# Prints the first line of an Azure CLI error message.
first_error_line() {
    printf '%s\n' "$1" | head -n 1
}

# Deletes test resource groups that are older than the maximum age.
sweep_stale_resource_groups() {
    local now max_age_seconds groups name created err
    now=$(date +%s)
    max_age_seconds=$((AZURE_CLEANUP_MAX_AGE_HOURS * 3600))

    if ! groups=$(az group list "${SUB_ARGS[@]}" \
        --query "[?starts_with(name, '${TEST_RG_PREFIX}')].[name, tags.creationTime]" \
        --output tsv); then
        echo "Warning: could not list resource groups; skipping stale resource group sweep." >&2
        return 0
    fi

    while IFS=$'\t' read -r name created; do
        [[ -z "$name" || "$name" == "$AZURE_RESOURCE_GROUP" ]] && continue
        created="${created//$'\r'/}"
        if [[ ! "$created" =~ ^[0-9]+$ ]]; then
            echo "Skipping resource group '$name': no valid creationTime tag."
            continue
        fi
        if (( now - created < max_age_seconds )); then
            continue
        fi
        echo "Deleting stale test resource group '$name' (created $(( (now - created) / 3600 )) hours ago)"
        if ! err=$(az group delete --name "$name" --yes --no-wait "${SUB_ARGS[@]}" 2>&1); then
            echo "Warning: could not delete resource group '$name': $(first_error_line "$err")" >&2
        fi
    done <<< "$groups"
}

# Purges soft-deleted Key Vaults that were in test resource groups.
purge_deleted_test_key_vaults() {
    local vaults name location err

    if ! vaults=$(az keyvault list-deleted --resource-type vault "${SUB_ARGS[@]}" \
        --query "[?contains(properties.vaultId, '/resourceGroups/${TEST_RG_PREFIX}')].[name, properties.location]" \
        --output tsv); then
        echo "Warning: could not list soft-deleted Key Vaults; skipping purge." >&2
        return 0
    fi

    while IFS=$'\t' read -r name location; do
        [[ -z "$name" ]] && continue
        location="${location//$'\r'/}"
        echo "Purging soft-deleted test Key Vault '$name' ($location)"
        if ! err=$(az keyvault purge --name "$name" --location "$location" --no-wait "${SUB_ARGS[@]}" 2>&1); then
            # DeletedVaultNotFound means that a purge of the vault already started.
            echo "Warning: could not purge Key Vault '$name': $(first_error_line "$err")" >&2
        fi
    done <<< "$vaults"
}

if [[ "$AZURE_CLEANUP_SWEEP" != "true" ]]; then
    echo "Sweep of leftover test resources is disabled."
    exit 0
fi

if [[ ! "$AZURE_CLEANUP_MAX_AGE_HOURS" =~ ^[0-9]+$ ]]; then
    echo "Warning: AZURE_CLEANUP_MAX_AGE_HOURS must be a whole number; skipping sweep." >&2
    exit 0
fi

echo "Sweeping leftover test resources from earlier runs"
sweep_stale_resource_groups || true
purge_deleted_test_key_vaults || true
echo "Sweep of leftover test resources complete"
