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
# Publish a single Terraform recipe to the Kubernetes module server.
# This script accepts a path to a Terraform recipe directory and publishes it
# to the ConfigMap-backed web server running in the cluster.
#
# Usage: ./build-terraform-recipe.sh <path-to-terraform-recipe-directory>
# Example: ./build-terraform-recipe.sh Security/secrets/recipes/kubernetes/terraform
# =============================================================================

set -euo pipefail

TERRAFORM_MODULE_SERVER_NAMESPACE="radius-test-tf-module-server"
TERRAFORM_MODULE_CONFIGMAP_NAME="tf-module-server-content"

# Cleanup temporary files on exit
TMP_DIR=""
cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Validate prerequisites
if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl is required but not installed" >&2
    exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
    echo "Error: zip is required but not installed" >&2
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: Cannot connect to Kubernetes cluster" >&2
    exit 1
fi

# Parse arguments
RECIPE_DIR="${1:-}"
if [[ -z "$RECIPE_DIR" ]]; then
    echo "Error: Recipe directory path is required" >&2
    echo "Usage: $0 <path-to-terraform-recipe-directory>" >&2
    exit 1
fi

# Normalize to absolute path, then convert to relative
if [[ "$RECIPE_DIR" != /* ]]; then
    RECIPE_DIR="$(pwd)/$RECIPE_DIR"
fi
RECIPE_DIR="$(cd "$RECIPE_DIR" 2>/dev/null && pwd)" || {
    echo "Error: Recipe directory not found: ${1:-}" >&2
    exit 1
}

if [[ ! -f "$RECIPE_DIR/main.tf" ]]; then
    echo "Error: main.tf not found in recipe directory: $RECIPE_DIR" >&2
    exit 1
fi

# Convert to relative path for pattern matching
RECIPE_PATH="$(realpath --relative-to="$(pwd)" "$RECIPE_DIR" 2>/dev/null || echo "$RECIPE_DIR")"

# Extract recipe metadata from path
# Expected pattern: <Category>/<ResourceType>/recipes/<Platform>/terraform
# Remove leading ./ and trailing /
RECIPE_PATH="${RECIPE_PATH#./}"
RECIPE_PATH="${RECIPE_PATH%/}"

if [[ ! "$RECIPE_PATH" =~ ^([^/]+)/([^/]+)/recipes/([^/]+)/terraform$ ]]; then
    echo "Error: Recipe path must match pattern: <Category>/<ResourceType>/recipes/<Platform>/terraform" >&2
    echo "Got: $RECIPE_PATH" >&2
    exit 1
fi

CATEGORY="${BASH_REMATCH[1]}"
RESOURCE_TYPE="${BASH_REMATCH[2]}"
PLATFORM="${BASH_REMATCH[3]}"
RECIPE_NAME="${RESOURCE_TYPE}-${PLATFORM}"

echo "==> Publishing Terraform recipe: $RECIPE_NAME"
echo "    Category: $CATEGORY"
echo "    Resource Type: $RESOURCE_TYPE"
echo "    Platform: $PLATFORM"

# Create temporary directory for ZIP file
TMP_DIR=$(mktemp -d)
ZIP_FILE="$TMP_DIR/${RECIPE_NAME}.zip"

# Create ZIP archive
echo "==> Creating ZIP archive: ${RECIPE_NAME}.zip"
if ! (cd "$RECIPE_DIR" && zip -q -r "$ZIP_FILE" .); then
    echo "Error: Failed to create ZIP file" >&2
    exit 1
fi

# Ensure namespace exists
if ! kubectl get namespace "$TERRAFORM_MODULE_SERVER_NAMESPACE" >/dev/null 2>&1; then
    echo "==> Creating namespace: $TERRAFORM_MODULE_SERVER_NAMESPACE"
    kubectl create namespace "$TERRAFORM_MODULE_SERVER_NAMESPACE"
fi

# Get existing ConfigMap data if it exists
echo "==> Updating ConfigMap: $TERRAFORM_MODULE_CONFIGMAP_NAME"
CONFIGMAP_EXISTS=false
if kubectl get configmap "$TERRAFORM_MODULE_CONFIGMAP_NAME" \
    -n "$TERRAFORM_MODULE_SERVER_NAMESPACE" >/dev/null 2>&1; then
    CONFIGMAP_EXISTS=true
fi

if [[ "$CONFIGMAP_EXISTS" == "true" ]]; then
    # Update existing ConfigMap by patching
    echo "    ConfigMap exists, updating with new recipe..."
    
    # Create patch file
    PATCH_FILE="$TMP_DIR/patch.yaml"
    cat > "$PATCH_FILE" <<EOF
binaryData:
  ${RECIPE_NAME}.zip: $(base64 -w 0 < "$ZIP_FILE")
EOF
    
    kubectl patch configmap "$TERRAFORM_MODULE_CONFIGMAP_NAME" \
        -n "$TERRAFORM_MODULE_SERVER_NAMESPACE" \
        --type merge \
        --patch-file "$PATCH_FILE"
else
    # Create new ConfigMap
    echo "    Creating new ConfigMap..."
    kubectl create configmap "$TERRAFORM_MODULE_CONFIGMAP_NAME" \
        --namespace "$TERRAFORM_MODULE_SERVER_NAMESPACE" \
        --from-file="${RECIPE_NAME}.zip=$ZIP_FILE"
fi

# Ensure web server deployment exists
echo "==> Ensuring web server is deployed..."
DEPLOYMENT_EXISTS=false
if kubectl get deployment tf-module-server \
    -n "$TERRAFORM_MODULE_SERVER_NAMESPACE" >/dev/null 2>&1; then
    DEPLOYMENT_EXISTS=true
fi

if [[ "$DEPLOYMENT_EXISTS" == "false" ]]; then
    echo "    Deploying web server..."
    RESOURCES_FILE=".github/build/tf-module-server/resources.yaml"
    
    if [[ ! -f "$RESOURCES_FILE" ]]; then
        echo "Error: Resources file not found: $RESOURCES_FILE" >&2
        exit 1
    fi
    
    kubectl apply -f "$RESOURCES_FILE" -n "$TERRAFORM_MODULE_SERVER_NAMESPACE" >/dev/null 2>&1
    
    echo "    Waiting for deployment to be ready..."
    if ! kubectl rollout status deployment.apps/tf-module-server \
        -n "$TERRAFORM_MODULE_SERVER_NAMESPACE" --timeout=60s >/dev/null 2>&1; then
        echo "Warning: Deployment may not have completed successfully" >&2
    fi
else
    echo "    Web server already deployed"
    # Restart deployment to pick up ConfigMap changes
    kubectl rollout restart deployment/tf-module-server \
        -n "$TERRAFORM_MODULE_SERVER_NAMESPACE" >/dev/null 2>&1
fi

echo ""
echo "============================================================================"
echo "Recipe Published Successfully"
echo "============================================================================"
echo "Recipe: $RECIPE_NAME"
echo ""
echo "Cluster-internal URL (for Radius):"
echo "  http://tf-module-server.$TERRAFORM_MODULE_SERVER_NAMESPACE.svc.cluster.local/${RECIPE_NAME}.zip"
echo ""
echo "To test locally, run:"
echo "  kubectl port-forward svc/tf-module-server 8999:80 -n $TERRAFORM_MODULE_SERVER_NAMESPACE"
echo ""
echo "Then access recipe at:"
echo "  http://localhost:8999/${RECIPE_NAME}.zip"
echo ""
