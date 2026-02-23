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

ensure_namespace_ready() {
    # Ensure the test namespace exists before deploying
    if ! kubectl get namespace testapp >/dev/null 2>&1; then
        kubectl create namespace testapp
    fi

    # Update the env with kubernetes provider
    rad env update "$ENVIRONMENT_NAME" --kubernetes-namespace testapp --preview

    echo "==> Environment Updated with Kubernetes provider:"
    rad env show "$ENVIRONMENT_NAME" -o json --preview || true
}

ensure_workspace_context() {
    # Ensure we are operating in the expected workspace context
    rad workspace switch "$WORKSPACE_NAME" >/dev/null 2>&1 || true
}

resolve_environment_path() {
    # Resolve the full environment resource ID to avoid hardcoding the provider path
    if ! ENVIRONMENT_JSON=$(rad env show "$ENVIRONMENT_NAME" --workspace "$WORKSPACE_NAME" -o json --preview 2>/dev/null); then
        echo "Error: Environment '$ENVIRONMENT_NAME' was not found in workspace '$WORKSPACE_NAME'."
        exit 1
    fi

    ENVIRONMENT_PATH=$(echo "$ENVIRONMENT_JSON" | jq -r 'if type=="object" then (.id // "") elif type=="array" and length>0 then (.[0].id // "") else "" end')
    if [[ -z "$ENVIRONMENT_PATH" ]]; then
        echo "Error: Could not determine environment id from rad env show output."
        echo "$ENVIRONMENT_JSON"
        exit 1
    fi
    echo "==> Environment path: $ENVIRONMENT_PATH"
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

ensure_workspace_context
resolve_environment_path

# Check if test file exists
TEST_FILE="$RESOURCE_TYPE_PATH/test/app.bicep"
if [[ ! -f "$TEST_FILE" ]]; then
    echo "==> No test file found at $TEST_FILE, skipping deployment test"
    exit 0
fi

echo "==> Deploying test application from $TEST_FILE"
APP_NAME="testapp-$(date +%s)"

# Ensure the target namespace exist before deploying
ensure_namespace_ready
 
# Deploy the test app
if rad deploy "$TEST_FILE" --application "$APP_NAME" -e "$ENVIRONMENT_NAME"; then
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