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
# Configure the Radius control plane with Azure workload identity credentials
# so Azure recipes can be tested. This script assumes the caller has
# already authenticated with Azure via `az login` or the GitHub Actions
# `azure/login` action. It creates (or reuses) a dedicated workspace,
# environment, and credential, then updates the environment with the Azure
# subscription and resource group used for testing.
# =============================================================================

set -euo pipefail

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "Error: environment variable '$name' must be set" >&2
        exit 1
    fi
}

ensure_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command '$cmd' not found in PATH" >&2
        exit 1
    fi
}

ensure_command "az"
ensure_command "rad"

require_env "AZURE_SUBSCRIPTION_ID"
require_env "AZURE_TENANT_ID"
require_env "AZURE_CLIENT_ID"

AZURE_LOCATION="${AZURE_LOCATION:-westus3}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
AZURE_WORKSPACE_NAME="${AZURE_WORKSPACE_NAME:-default}"
AZURE_ENVIRONMENT_NAME="${AZURE_ENVIRONMENT_NAME:-default}"
AZURE_TEST_STATE_FILE="${AZURE_TEST_STATE_FILE:-.azure-test-state}"
RADIUS_GROUP_NAME="${RADIUS_GROUP_NAME:-default}"

if [[ -z "$AZURE_RESOURCE_GROUP" ]]; then
    echo "Error: AZURE_RESOURCE_GROUP must be provided" >&2
    exit 1
fi

printf "\033[34;1m=>\033[0m Configuring Azure provider for Radius tests\n"

if ! az group exists --name "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" >/dev/null 2>&1; then
    echo "Error: Azure resource group '$AZURE_RESOURCE_GROUP' not found. Create it before running configure-azure-provider." >&2
    exit 1
fi

printf "\033[34;1m=>\033[0m Updating environment '%s' with Azure provider settings\n" "$AZURE_ENVIRONMENT_NAME"
rad env update "$AZURE_ENVIRONMENT_NAME" \
    --azure-subscription-id "$AZURE_SUBSCRIPTION_ID" \
    --azure-resource-group "$AZURE_RESOURCE_GROUP"

printf "\033[34;1m=>\033[0m Registering Azure workload identity credential\n"
rad credential register azure wi \
    --tenant-id "$AZURE_TENANT_ID" \
    --client-id "$AZURE_CLIENT_ID"

cat <<EOF >"$AZURE_TEST_STATE_FILE"
AZURE_RESOURCE_GROUP=$AZURE_RESOURCE_GROUP
AZURE_LOCATION=$AZURE_LOCATION
AZURE_WORKSPACE_NAME=$AZURE_WORKSPACE_NAME
AZURE_ENVIRONMENT_NAME=$AZURE_ENVIRONMENT_NAME
AZURE_SUBSCRIPTION_ID=$AZURE_SUBSCRIPTION_ID
RADIUS_GROUP_NAME=$RADIUS_GROUP_NAME
EOF

printf "\033[34;1m=>\033[0m Azure provider configured. State written to %s\n" "$AZURE_TEST_STATE_FILE"
