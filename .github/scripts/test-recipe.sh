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
ENVIRONMENT_PATH="${2:-/planes/radius/local/resourceGroups/default/providers/Radius.Core/environments/default}"

ensure_namespace_ready() {
    # Ensure the test namespace exists before deploying
    if ! kubectl get namespace testapp >/dev/null 2>&1; then
        kubectl create namespace testapp
    fi

    # Update the env with kubernetes provider
    rad env update default --kubernetes-namespace testapp --preview

    echo "==> Environment Updated with Kubernetes provider:"
    rad env show "$ENVIRONMENT_PATH" -o json --preview || true
}

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

# Determine workspace and environment names based on platform
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

# Normalize overrides (allow env vars to win)
if [[ -n "$RADIUS_ENVIRONMENT_OVERRIDE" ]]; then
    ENVIRONMENT_NAME="$RADIUS_ENVIRONMENT_OVERRIDE"
fi

echo "==> Resource type: $RESOURCE_TYPE"
echo "==> Workspace: $WORKSPACE_NAME"
echo "==> Environment: $ENVIRONMENT_NAME"

# Determine template path based on recipe type
RECIPE_NAME="default"

if [[ "$RECIPE_TYPE" == "bicep" ]]; then
    # For Bicep, use OCI registry path (match build-bicep-recipe.sh format)
    # Path format: localhost:5000/radius-recipes/{category}/{resourcename}/{platform}/{language}/{recipe-filename}
    # Find the .bicep file in the recipe directory
    BICEP_FILE=$(ls "$RECIPE_PATH"/*.bicep 2>/dev/null | head -n 1)
    RECIPE_FILENAME=$(basename "$BICEP_FILE" .bicep)

    # Extract platform and language from path (e.g., recipes/kubernetes/bicep -> kubernetes/bicep)
    RECIPES_SUBPATH="${RECIPE_PATH#*recipes/}"

    # Build OCI path (use reciperegistry for in-cluster access)
    CATEGORY_LOWER=$(echo "$CATEGORY" | tr '[:upper:]' '[:lower:]')
    RESOURCE_LOWER=$(echo "$RESOURCE_NAME" | tr '[:upper:]' '[:lower:]')
    TEMPLATE_PATH="reciperegistry:5000/radius-recipes/${CATEGORY_LOWER}/${RESOURCE_LOWER}/${RECIPES_SUBPATH}/${RECIPE_FILENAME}:latest"
elif [[ "$RECIPE_TYPE" == "terraform" ]]; then
    # For Terraform, use HTTP module server with format: resourcename-platform.zip
    MODULE_NAME="${RESOURCE_NAME}-${PLATFORM}"
    TEMPLATE_PATH="http://tf-module-server.radius-test-tf-module-server.svc.cluster.local/${MODULE_NAME}.zip"
fi

echo "==> Registering recipe: $RECIPE_NAME"
rad recipe register "$RECIPE_NAME" \
    --workspace "$WORKSPACE_NAME" \
    --environment "$ENVIRONMENT_NAME" \
    --resource-type "$RESOURCE_TYPE" \
    --template-kind "$TEMPLATE_KIND" \
    --template-path "$TEMPLATE_PATH" \
    --plain-http

# Check if test file exists
TEST_FILE="$RESOURCE_TYPE_PATH/test/app.bicep"
if [[ ! -f "$TEST_FILE" ]]; then
    echo "==> No test file found at $TEST_FILE, skipping deployment test"
    rad recipe unregister "$RECIPE_NAME" \
        --workspace "$WORKSPACE_NAME" \
        --environment "$ENVIRONMENT_NAME" \
        --resource-type "$RESOURCE_TYPE"
    exit 0
fi

echo "==> Deploying test application from $TEST_FILE"
APP_NAME="testapp-$(date +%s)"

# Ensure the target namespace exist before deploying
ensure_namespace_ready
 
# Deploy the test app
if rad deploy "$TEST_FILE" --application "$APP_NAME" -e "/planes/radius/local/resourceGroups/default/providers/Radius.Core/environments/default"; then
    echo "==> Test deployment successful"
    
    # Cleanup: delete the app
    echo "==> Cleaning up test application"
    rad app delete "$APP_NAME" --yes
else
    echo "==> Test deployment failed"
    rad app delete "$APP_NAME" --yes 2>/dev/null || true
    rad recipe unregister "$RECIPE_NAME" \
        --workspace "$WORKSPACE_NAME" \
        --environment "$ENVIRONMENT_NAME" \
        --resource-type "$RESOURCE_TYPE"
    exit 1
fi

# Unregister the recipe
echo "==> Unregistering recipe"
rad recipe unregister "$RECIPE_NAME" \
    --workspace "$WORKSPACE_NAME" \
    --environment "$ENVIRONMENT_NAME" \
    --resource-type "$RESOURCE_TYPE"

echo "==> Test completed successfully"
