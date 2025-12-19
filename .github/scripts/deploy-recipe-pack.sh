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
# Deploy a Recipe Pack using Bicep template
#
# Usage: ./deploy-recipe-pack.sh <bicep-file> [resource-group] [subscription]
# Example: ./deploy-recipe-pack.sh recipe-pack.bicep
# =============================================================================

set -euo pipefail

BICEP_FILE="${1:-}"
RESOURCE_GROUP="${2:-}"
SUBSCRIPTION="${3:-}"

rad group switch default
rad env create default --preview
rad env switch default --preview
echo "Showing the created environment details:"
rad env show -o json --preview
echo "✅ Workspace and environment initialization completed successfully"

if [[ -z "$BICEP_FILE" ]]; then
    echo "Error: Bicep file is required"
    echo "Usage: $0 <bicep-file> [resource-group] [subscription]"
    exit 1
fi

if [[ ! -f "$BICEP_FILE" ]]; then
    echo "Error: Bicep file not found: $BICEP_FILE"
    exit 1
fi

echo "==> Deploying recipe pack from $BICEP_FILE"

# Use rad deploy command with Bicep file
DEPLOY_ARGS=("deploy" "$BICEP_FILE")

if [[ -n "$RESOURCE_GROUP" ]]; then
    DEPLOY_ARGS+=("--group" "$RESOURCE_GROUP")
fi

if [[ -n "$SUBSCRIPTION" ]]; then
    DEPLOY_ARGS+=("--subscription" "$SUBSCRIPTION")
fi

echo "==> Running: rad ${DEPLOY_ARGS[*]}"
rad "${DEPLOY_ARGS[@]}" --parameters environment=/planes/radius/local/resourceGroups/default/providers/Radius.Core/environments/default

echo "==> Recipe pack deployed successfully"

