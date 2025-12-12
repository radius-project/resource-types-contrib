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
rad "${DEPLOY_ARGS[@]}"

echo "==> Recipe pack deployed successfully"

# Extract recipe pack name from the Bicep file
RECIPE_PACK_NAME=$(grep -E "name: '[^']*'" "$BICEP_FILE" | sed -E "s/.*name: '([^']*)'.*/\1/" | head -1)
if [[ -z "$RECIPE_PACK_NAME" ]]; then
    echo "Warning: Could not extract recipe pack name from $BICEP_FILE"
    RECIPE_PACK_NAME="biceprecipepack"
fi

# Get current resource group and subscription
CURRENT_RG=$(rad group show --output table | grep -v "NAME" | awk '{print $1}' | head -1)
if [[ -z "$CURRENT_RG" ]]; then
    CURRENT_RG="default"
fi

# Build recipe pack resource ID
RECIPE_PACK_ID="/planes/radius/local/resourcegroups/${CURRENT_RG}/providers/Radius.Core/recipePacks/${RECIPE_PACK_NAME}"

echo "==> Updating environment to use recipe pack"
echo "==> Recipe pack ID: $RECIPE_PACK_ID"

# Update the environment with the recipe pack
rad env update default --recipe-packs "$RECIPE_PACK_ID"

echo "==> Environment updated successfully"

# Verify deployment by listing recipe packs
echo "==> Verifying deployment..."
rad recipe list --environment default || echo "Warning: Could not verify recipe pack deployment"