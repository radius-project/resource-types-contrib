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
# Register a single Radius recipe. Automatically detects whether the recipe 
# is Bicep or Terraform and registers it with the appropriate template path.
#
# Usage: ./register-recipe.sh <path-to-recipe-directory>
# Example: ./register-recipe.sh Security/secrets/recipes/kubernetes/bicep
# =============================================================================

set -euo pipefail

RECIPE_PATH="${1:-}"

if [[ -z "$RECIPE_PATH" ]]; then
    echo "Error: Recipe path is required"
    echo "Usage: $0 <path-to-recipe-directory>"
    exit 1
fi

if [[ ! -d "$RECIPE_PATH" ]]; then
    echo "Error: Recipe directory not found: $RECIPE_PATH"
    exit 1
fi

# Normalize path: convert absolute to relative for consistency
RECIPE_PATH="$(realpath --relative-to="$(pwd)" "$RECIPE_PATH" 2>/dev/null || echo "$RECIPE_PATH")"
RECIPE_PATH="${RECIPE_PATH#./}"

# Detect recipe type based on file presence
if [[ -f "$RECIPE_PATH/main.tf" ]]; then
    RECIPE_TYPE="terraform"
    TEMPLATE_KIND="terraform"
elif ls "$RECIPE_PATH"/*.bicep &>/dev/null; then
    RECIPE_TYPE="bicep"
    TEMPLATE_KIND="bicep"
else
    echo "Error: Could not detect recipe type in $RECIPE_PATH"
    exit 1
fi

echo "==> Registering $RECIPE_TYPE recipe at $RECIPE_PATH"

# Extract resource type from path (e.g., Security/secrets -> Radius.Security/secrets)
RESOURCE_TYPE_PATH=$(echo "$RECIPE_PATH" | sed -E 's|/recipes/.*||')
CATEGORY=$(basename "$(dirname "$RESOURCE_TYPE_PATH")")
RESOURCE_NAME=$(basename "$RESOURCE_TYPE_PATH")
RESOURCE_TYPE="Radius.$CATEGORY/$RESOURCE_NAME"

echo "==> Resource type: $RESOURCE_TYPE"

# Determine template path based on recipe type
if [[ "$RECIPE_TYPE" == "bicep" ]]; then
    # For Bicep, use OCI registry path (match build-bicep-recipe.sh format)
    # Path format: localhost:5000/radius-recipes/{category}/{resourcename}/{platform}/{language}/{recipe-filename}
    # Find the .bicep file in the recipe directory
    BICEP_FILE=$(ls "$RECIPE_PATH"/*.bicep 2>/dev/null | head -n 1)
    RECIPE_FILENAME=$(basename "$BICEP_FILE" .bicep)
    RECIPE_NAME="$RECIPE_FILENAME"
 
 # Extract platform and language from path (e.g., recipes/kubernetes/bicep -> kubernetes/bicep)
    RECIPES_SUBPATH="${RECIPE_PATH#*recipes/}"
    
    # Build OCI path (use reciperegistry for in-cluster access)
    # Note: Build script pushes to localhost:5000 (which is port-forwarded to reciperegistry)
    # But Radius running in-cluster needs to pull from reciperegistry:5000
    CATEGORY_LOWER=$(echo "$CATEGORY" | tr '[:upper:]' '[:lower:]')
    RESOURCE_LOWER=$(echo "$RESOURCE_NAME" | tr '[:upper:]' '[:lower:]')
    TEMPLATE_PATH="reciperegistry:5000/radius-recipes/${CATEGORY_LOWER}/${RESOURCE_LOWER}/${RECIPES_SUBPATH}/${RECIPE_FILENAME}:latest"

elif [[ "$RECIPE_TYPE" == "terraform" ]]; then
    # For Terraform, use HTTP module server with format: resourcename-platform.zip
    PLATFORM=$(basename "$(dirname "$RECIPE_PATH")")
    RECIPE_NAME="${RESOURCE_NAME}-${PLATFORM}"
    TEMPLATE_PATH="http://tf-module-server.radius-test-tf-module-server.svc.cluster.local/${RECIPE_NAME}.zip"
fi

echo "==> Registering recipe: $RECIPE_NAME"
echo "==> Template path: $TEMPLATE_PATH"

rad recipe register default \
    --environment default \
    --resource-type "$RESOURCE_TYPE" \
    --template-kind "$TEMPLATE_KIND" \
    --template-path "$TEMPLATE_PATH" \
    --plain-http

echo "==> Recipe registered successfully"

# Log the registered recipe details
echo "==> Verifying registration..."
rad recipe show default --resource-type "$RESOURCE_TYPE" --environment default || echo "Warning: Could not verify recipe registration"