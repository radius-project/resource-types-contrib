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
# Test a single Radius recipe by deploying a test app and cleaning up.
# Assumes the recipe has already been registered.
#
# Usage: ./test-recipe.sh <path-to-recipe-directory>
# Example: ./test-recipe.sh Security/secrets/recipes/kubernetes/bicep
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
elif ls "$RECIPE_PATH"/*.bicep &>/dev/null; then
    RECIPE_TYPE="bicep"
else
    echo "Error: Could not detect recipe type in $RECIPE_PATH"
    exit 1
fi

echo "==> Testing $RECIPE_TYPE recipe at $RECIPE_PATH"

# Extract resource type from path (e.g., Security/secrets -> Radius.Security/secrets)
RESOURCE_TYPE_PATH=$(echo "$RECIPE_PATH" | sed -E 's|/recipes/.*||')
CATEGORY=$(basename "$(dirname "$RESOURCE_TYPE_PATH")")
RESOURCE_NAME=$(basename "$RESOURCE_TYPE_PATH")
RESOURCE_TYPE="Radius.$CATEGORY/$RESOURCE_NAME"

echo "==> Assuming recipe is already registered"
echo "==> Resource type: $RESOURCE_TYPE"

# Check if test file exists
TEST_FILE="$RESOURCE_TYPE_PATH/test/app.bicep"
if [[ ! -f "$TEST_FILE" ]]; then
    echo "==> No test file found at $TEST_FILE, skipping deployment test"
    exit 0
fi

echo "==> Deploying test application from $TEST_FILE"
APP_NAME="testapp-$(date +%s)"

# Deploy the test app
if rad deploy "$TEST_FILE" --application "$APP_NAME" --environment default; then
    echo "==> Test deployment successful"
    
    # Cleanup: delete the app
    echo "==> Cleaning up test application"
    rad app delete "$APP_NAME" --yes
else
    echo "==> Test deployment failed"
    rad app delete "$APP_NAME" --yes 2>/dev/null || true
    exit 1
fi

echo "==> Test completed successfully"
