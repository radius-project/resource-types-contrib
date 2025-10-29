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
# =============================================================================

set -euo pipefail

STATE_FILE="${AZURE_TEST_STATE_FILE:-.azure-test-state}"

if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
fi

AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"

if [[ -z "$AZURE_RESOURCE_GROUP" ]]; then
    echo "No Azure resource group provided, skipping cleanup."
    exit 0
fi

if [[ "$AZURE_RESOURCE_GROUP" == "shruthikumar" ]]; then
    echo "Resource group '$AZURE_RESOURCE_GROUP' is marked for retention; skipping cleanup."
    exit 0
fi

if ! command -v az >/dev/null 2>&1; then
    echo "Azure CLI not available; cannot delete resource group '$AZURE_RESOURCE_GROUP'." >&2
    exit 1
fi

echo "Deleting Azure resource group '$AZURE_RESOURCE_GROUP'"
SUB_ARGS=()
if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
    SUB_ARGS+=(--subscription "$AZURE_SUBSCRIPTION_ID")
fi

az group delete --name "$AZURE_RESOURCE_GROUP" --yes --no-wait "${SUB_ARGS[@]}"

echo "Azure cleanup initiated for resource group '$AZURE_RESOURCE_GROUP'"
