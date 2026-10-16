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
# Test a single Radius recipe by registering it, deploying a test app, and 
# cleaning up. Automatically detects whether the recipe is Bicep or Terraform.
#
# Usage: ./test-recipe.sh <path-to-recipe-directory>
# Example: ./test-recipe.sh Security/secrets/recipes/kubernetes/bicep
# =============================================================================

set -euo pipefail

RECIPE_PATH="${1:-}"
ENVIRONMENT_NAME_OVERRIDE="${2:-}"
ENVIRONMENT_PATH=""
KUBERNETES_NAMESPACE=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-recipe-test.sh
source "$SCRIPT_DIR/lib-recipe-test.sh"

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

echo "==> Testing $RECIPE_TYPE recipe at $RECIPE_PATH"

# Extract resource type from path (e.g., Security/secrets -> Radius.Security/secrets)
RESOURCE_TYPE_PATH=$(echo "$RECIPE_PATH" | sed -E 's|/recipes/.*||')
CATEGORY=$(basename "$(dirname "$RESOURCE_TYPE_PATH")")
RESOURCE_NAME=$(basename "$RESOURCE_TYPE_PATH")
RESOURCE_TYPE="Radius.$CATEGORY/$RESOURCE_NAME"

# Derive platform from recipe path (first segment after recipes/)
RECIPES_RELATIVE="${RECIPE_PATH#${RESOURCE_TYPE_PATH}/recipes/}"
PLATFORM="${RECIPES_RELATIVE%%/*}"

# Determine workspace and environment names based on platform (with overrides)
RADIUS_WORKSPACE_OVERRIDE="${RADIUS_WORKSPACE_OVERRIDE:-}"
RADIUS_ENVIRONMENT_OVERRIDE="${RADIUS_ENVIRONMENT_OVERRIDE:-}"

KUBERNETES_WORKSPACE_NAME="${KUBERNETES_WORKSPACE_NAME:-default}"
KUBERNETES_ENVIRONMENT_NAME="${KUBERNETES_ENVIRONMENT_NAME:-default}"
AZURE_WORKSPACE_NAME="${AZURE_WORKSPACE_NAME:-azure}"
AZURE_ENVIRONMENT_NAME="${AZURE_ENVIRONMENT_NAME:-azure}"

WORKSPACE_NAME="$KUBERNETES_WORKSPACE_NAME"
ENVIRONMENT_NAME="$KUBERNETES_ENVIRONMENT_NAME"

case "$PLATFORM" in
    azure)
        WORKSPACE_NAME="$AZURE_WORKSPACE_NAME"
        ENVIRONMENT_NAME="$AZURE_ENVIRONMENT_NAME"
        ;;
    kubernetes)
        WORKSPACE_NAME="$KUBERNETES_WORKSPACE_NAME"
        ENVIRONMENT_NAME="$KUBERNETES_ENVIRONMENT_NAME"
        ;;
    "")
        # Fallback to defaults when the platform segment is missing
        WORKSPACE_NAME="$KUBERNETES_WORKSPACE_NAME"
        ENVIRONMENT_NAME="$KUBERNETES_ENVIRONMENT_NAME"
        ;;
    *)
        # Additional platforms default to Kubernetes workspace/environment unless overridden
        WORKSPACE_NAME="$KUBERNETES_WORKSPACE_NAME"
        ENVIRONMENT_NAME="$KUBERNETES_ENVIRONMENT_NAME"
        ;;
esac

if [[ -n "$RADIUS_WORKSPACE_OVERRIDE" ]]; then
    WORKSPACE_NAME="$RADIUS_WORKSPACE_OVERRIDE"
fi

if [[ -n "$RADIUS_ENVIRONMENT_OVERRIDE" ]]; then
    ENVIRONMENT_NAME="$RADIUS_ENVIRONMENT_OVERRIDE"
fi

if [[ -n "$ENVIRONMENT_NAME_OVERRIDE" ]]; then
    ENVIRONMENT_NAME="$ENVIRONMENT_NAME_OVERRIDE"
fi

echo "==> Resource type: $RESOURCE_TYPE"
echo "==> Workspace: $WORKSPACE_NAME"
echo "==> Environment: $ENVIRONMENT_NAME"

rtc_ensure_workspace_context "$WORKSPACE_NAME"
if ! RESOLVED=$(rtc_resolve_environment_path "$ENVIRONMENT_NAME" "$WORKSPACE_NAME"); then
    exit 1
fi
IFS=$'\t' read -r ENVIRONMENT_PATH KUBERNETES_NAMESPACE <<<"$RESOLVED"
echo "==> Environment path: $ENVIRONMENT_PATH"

# Check if test file exists
TEST_FILE="$RESOURCE_TYPE_PATH/test/app.bicep"
if [[ ! -f "$TEST_FILE" ]]; then
    echo "==> No test file found at $TEST_FILE, skipping deployment test"
    exit 0
fi

if rtc_deploy_and_assert_test_app "$TEST_FILE" "$RESOURCE_TYPE" "testapp" "$ENVIRONMENT_PATH" "$WORKSPACE_NAME" "$KUBERNETES_NAMESPACE"; then
    : # Falls through to the shared success message below.
else
    rad recipe unregister default \
        --workspace "$WORKSPACE_NAME" \
        --environment "$ENVIRONMENT_PATH" \
        --resource-type "$RESOURCE_TYPE"
    exit 1
fi

echo "==> Test completed successfully"
