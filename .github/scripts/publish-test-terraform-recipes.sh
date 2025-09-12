#!/bin/bash

# ------------------------------------------------------------
# Copyright 2023 The Radius Authors.
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

# ============================================================================
# Publish Terraform recipes to Kubernetes ConfigMap
# Finds Terraform recipes, creates zip files, and stores them in a ConfigMap
# ============================================================================

set -euo pipefail

# Default values
TERRAFORM_MODULE_SERVER_NAMESPACE="radius-test-tf-module-server"
TERRAFORM_MODULE_CONFIGMAP_NAME="tf-module-server-content"

# Source common validation functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/validate-common.sh"

# Function to log messages to both stdout and GitHub Actions step summary
log() {
    local message="$1"
    echo "$message"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "$message" >> "$GITHUB_STEP_SUMMARY"
    fi
}

# Validate requirements
validate_requirements() {
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "Error: kubectl is not installed or not in PATH" >&2
        exit 1
    fi
    
    if ! command -v zip >/dev/null 2>&1; then
        echo "Error: zip utility is not installed or not in PATH" >&2
        exit 1
    fi
}

# Create namespace if it doesn't exist
create_namespace() {
    local namespace="$1"
    echo "=> Creating Kubernetes namespace $namespace..." >&2
    kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# Find and prepare recipes
prepare_recipes() {
    echo "=> Finding and publishing Terraform recipes..." >&2
    
    # Setup configuration from validate-common.sh
    setup_config
    
    # Find terraform recipes
    readarray -t terraform_recipes < <(find_and_validate_recipes "*/recipes/kubernetes/terraform/main.tf" "Terraform")
    
    # Create temporary directory for recipes
    local temp_recipes_dir
    temp_recipes_dir=$(mktemp -d)
    echo "Using temporary directory: $temp_recipes_dir" >&2
    
    # Copy recipes to temporary directory
    for recipe_file in "${terraform_recipes[@]}"; do
        read -r _ resource_type platform_service _ <<< "$(extract_recipe_info "$recipe_file")"
        local recipe_dir
        recipe_dir=$(dirname "$recipe_file")
        local recipe_name="$resource_type-$platform_service"
        echo "Copying recipe from $recipe_dir to $temp_recipes_dir/$recipe_name" >&2
        cp -r "$recipe_dir" "$temp_recipes_dir/$recipe_name"
    done
    
    # Return the temp directory path via stdout
    echo "$temp_recipes_dir"
}


# Deploy web server
deploy_web_server() {
    local namespace="$1"
    echo "=> Deploying web server..." >&2
    kubectl apply -f "$SCRIPT_DIR/../build/tf-module-server/resources.yaml" -n "$namespace" >/dev/null
    
    echo "=> Waiting for web server to be ready..." >&2
    kubectl rollout status deployment.apps/tf-module-server -n "$namespace" --timeout=600s >/dev/null
    
    echo "=> Web server ready. Recipes published to http://tf-module-server.$namespace.svc.cluster.local/<recipe_name>.zip" >&2
    echo "=> To test use:" >&2
    echo "=>     kubectl port-forward svc/tf-module-server 8999:80 -n $namespace" >&2
    echo "=>     curl http://localhost:8999/<recipe-name>.zip --output <recipe-name>.zip" >&2
}

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
    if [[ -n "${TEMP_RECIPES_DIR:-}" && -d "$TEMP_RECIPES_DIR" ]]; then
        rm -rf "$TEMP_RECIPES_DIR"
    fi
}

main() {
    validate_requirements
    
    # Create namespace
    create_namespace "$TERRAFORM_MODULE_SERVER_NAMESPACE"
    
    # Prepare recipes
    TEMP_RECIPES_DIR=$(prepare_recipes)
    trap cleanup EXIT
    
    # Create temporary directory for zip files
    TMP_DIR=$(mktemp -d)
    
    log "Publishing recipes from $TEMP_RECIPES_DIR to $TERRAFORM_MODULE_SERVER_NAMESPACE/$TERRAFORM_MODULE_CONFIGMAP_NAME"
    
    # Build kubectl command arguments directly
    local kubectl_args=("kubectl" "create" "configmap" "$TERRAFORM_MODULE_CONFIGMAP_NAME" "--namespace" "$TERRAFORM_MODULE_SERVER_NAMESPACE")
    
    # Process each recipe directory and build command
    local recipe_count=0
    for recipe_dir in "$TEMP_RECIPES_DIR"/*/; do
        [[ -d "$recipe_dir" ]] || continue
        
        local recipe_name
        recipe_name=$(basename "$recipe_dir")
        local zip_file="$TMP_DIR/$recipe_name.zip"
        
        log "Processing recipe: $recipe_name"
        (cd "$recipe_dir" && zip -r "$zip_file" . >/dev/null)
        
        kubectl_args+=("--from-file=$recipe_name.zip=$zip_file")
        recipe_count=$((recipe_count + 1))
    done
    
    if [[ $recipe_count -eq 0 ]]; then
        echo "Error: No recipes found in $TEMP_RECIPES_DIR" >&2
        exit 1
    fi
    
    # Delete existing configmap
    log "Removing existing configmap if present"
    kubectl delete configmap "$TERRAFORM_MODULE_CONFIGMAP_NAME" --namespace "$TERRAFORM_MODULE_SERVER_NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true
    
    # Create new configmap
    log "Creating configmap with $recipe_count recipes"
    "${kubectl_args[@]}" >/dev/null
    
    log "Successfully created configmap: $TERRAFORM_MODULE_SERVER_NAMESPACE/$TERRAFORM_MODULE_CONFIGMAP_NAME"
    
    # Deploy web server
    deploy_web_server "$TERRAFORM_MODULE_SERVER_NAMESPACE"
}

main "$@"