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
# Deletes the resource group recorded in the Azure test state file (if any).
# The OpenAI worker first purges accounts while the tagged group proves ownership.
# =============================================================================

set -euo pipefail

AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"

if [[ "${RTC_PURGE_OPENAI_ACCOUNTS:-false}" != true && "${RTC_PURGE_OPENAI_ACCOUNTS:-false}" != false ]]; then
    echo "Error: RTC_PURGE_OPENAI_ACCOUNTS must be true or false." >&2
    exit 1
fi

if [[ -z "$AZURE_RESOURCE_GROUP" ]]; then
    if [[ "${RTC_PURGE_OPENAI_ACCOUNTS:-false}" == true ]]; then
        echo "Error: OpenAI cleanup requires AZURE_RESOURCE_GROUP; capacity release is not confirmed." >&2
        exit 1
    fi
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

if ! exists="$(timeout --kill-after=5s 30s az group exists --name "$AZURE_RESOURCE_GROUP" "${SUB_ARGS[@]}" --output tsv)"; then
    echo "Error: Could not verify Azure resource group existence; capacity release is not confirmed." >&2
    exit 1
fi
if [[ "$exists" != true && "$exists" != false ]]; then
    echo "Error: Unexpected Azure resource group existence response; capacity release is not confirmed." >&2
    exit 1
fi

if [[ "${RTC_PURGE_OPENAI_ACCOUNTS:-false}" == true ]]; then
    if ! timeout --kill-after=5s 6m bash "$(dirname "${BASH_SOURCE[0]}")/cleanup-openai-accounts.sh" "$exists"; then
        echo "Error: OpenAI account cleanup failed or timed out; retaining the resource group for fallback cleanup." >&2
        exit 1
    fi
fi

if [[ "$exists" == false ]]; then
    echo "Azure resource group '$AZURE_RESOURCE_GROUP' is already absent; deletion confirmed"
    exit 0
fi

echo "Deleting Azure resource group '$AZURE_RESOURCE_GROUP'"
delete_status=0
timeout --kill-after=5s 12m az group delete --name "$AZURE_RESOURCE_GROUP" --yes "${SUB_ARGS[@]}" || delete_status=$?
if ! exists="$(timeout --kill-after=5s 30s az group exists --name "$AZURE_RESOURCE_GROUP" "${SUB_ARGS[@]}" --output tsv)"; then
    echo "Error: Could not verify Azure resource group deletion; capacity release is not confirmed." >&2
    exit 1
fi
if [[ "$delete_status" != 0 ]]; then
    echo "Error: Azure resource group deletion failed or timed out; capacity release is not confirmed." >&2
    exit 1
fi
if [[ "$exists" != false ]]; then
    echo "Error: Azure resource group '$AZURE_RESOURCE_GROUP' still exists; capacity release is not confirmed." >&2
    exit 1
fi

echo "Azure resource group '$AZURE_RESOURCE_GROUP' deletion confirmed"
