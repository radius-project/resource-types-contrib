#!/bin/bash

# ============================================================================
# Publish Terraform Recipes to Module Server
# ============================================================================
# This script discovers Terraform recipes in the repository, packages them
# into ZIP archives, publishes them to a Kubernetes ConfigMap, and deploys
# an nginx web server to serve the recipes over HTTP.
#
# Prerequisites:
#   - A Kubernetes cluster must be running (e.g., run "make create-radius-cluster" first)
#   - kubectl must be installed and configured
#   - zip utility must be installed
# ============================================================================

set -euo pipefail

# ============================================================================
# Constants
# ============================================================================

TERRAFORM_MODULE_SERVER_NAMESPACE="radius-test-tf-module-server"
TERRAFORM_MODULE_CONFIGMAP_NAME="tf-module-server-content"
TERRAFORM_MODULE_DEPLOYMENT_NAME="tf-module-server"
TERRAFORM_MODULE_SERVICE_NAME="tf-module-server"

# Temporary directories (cleaned up on exit)
TMP_DIR=""
TEMP_RECIPES_DIR=""

# ============================================================================
# Logging Functions
# ============================================================================

# Logs a message to stdout and optionally to GitHub Actions summary
# Args: message string
log() {
    local message="$1"
    echo "$message"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "$message" >> "$GITHUB_STEP_SUMMARY"
    fi
}

# ============================================================================
# Cleanup
# ============================================================================

# Removes temporary directories created during script execution
# Called automatically on script exit via trap
cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        echo "Cleaning up temporary directory: $TMP_DIR"
        rm -rf "$TMP_DIR"
    fi
    if [[ -n "${TEMP_RECIPES_DIR:-}" && -d "$TEMP_RECIPES_DIR" ]]; then
        echo "Cleaning up temporary recipes directory: $TEMP_RECIPES_DIR"
        rm -rf "$TEMP_RECIPES_DIR"
    fi
}

trap cleanup EXIT

# ============================================================================
# Validation Functions
# ============================================================================

# Validates that required tools are installed and cluster is accessible
# Exits with error if prerequisites are not met
validate_requirements() {
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "Error: kubectl is required but not installed" >&2
        exit 1
    fi
    
    if ! command -v zip >/dev/null 2>&1; then
        echo "Error: zip is required but not installed" >&2
        exit 1
    fi
    
    # Check if kubectl can connect to a cluster
    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo "Error: Cannot connect to Kubernetes cluster" >&2
        echo "Please ensure a cluster is running (e.g., run 'make create-radius-cluster' first)" >&2
        exit 1
    fi
}

# ============================================================================
# Kubernetes Functions
# ============================================================================

# Creates a Kubernetes namespace (idempotent)
# Args: namespace name
create_namespace() {
    local namespace="$1"
    echo "Creating namespace: $namespace"
    kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - 2>&1 | grep -v "unchanged" || true
}

# Deploys the nginx web server using Kubernetes resources
# Args: namespace name
deploy_web_server() {
    local namespace="$1"
    local resources_file=".github/build/tf-module-server/resources.yaml"
    
    if [[ ! -f "$resources_file" ]]; then
        echo "Error: Resources file not found: $resources_file" >&2
        exit 1
    fi
    
    echo "Deploying web server to namespace: $namespace"
    kubectl apply -f "$resources_file" -n "$namespace" 2>&1 | grep -v "unchanged" || true
}

# Waits for a Kubernetes deployment to be ready
# Args: namespace name, deployment name
wait_for_deployment() {
    local namespace="$1"
    local deployment="$2"
    
    echo "Waiting for deployment to be ready: $deployment"
    if ! kubectl rollout status deployment.apps/"$deployment" \
        -n "$namespace" --timeout=600s 2>&1 | grep -E "(successfully rolled out|deployment .* successfully rolled out)"; then
        echo "Warning: Deployment may not have completed successfully" >&2
    fi
}

# ============================================================================
# Recipe Discovery Functions
# ============================================================================

# Discovers all Terraform recipes in resource type folders
# Outputs recipe file paths to stdout (one per line)
# Logs progress to stderr
# Exits if no recipes are found
find_terraform_recipes() {
    local pattern="*/recipes/kubernetes/terraform/main.tf"
    local resource_folders=()
    local terraform_recipes=()
    
    # Get list of resource type folders
    while IFS= read -r folder; do
        resource_folders+=("$folder")
    done < <(./.github/scripts/list-resource-type-folders.sh)
    
    echo "Resource type folders found: ${#resource_folders[@]}" >&2
    
    # Find all Terraform recipes within resource type folders
    for folder in "${resource_folders[@]}"; do
        if [[ -d "$folder" ]]; then
            echo "Searching for Terraform recipes in folder: $folder" >&2
            while IFS= read -r -d '' recipe_file; do
                terraform_recipes+=("$recipe_file")
                echo "  Found: $recipe_file" >&2
            done < <(find "$folder" -path "$pattern" -type f -print0)
        fi
    done
    
    if [[ ${#terraform_recipes[@]} -eq 0 ]]; then
        echo "No Terraform recipes found" >&2
        exit 0
    fi
    
    echo "" >&2
    echo "Found ${#terraform_recipes[@]} Terraform recipe(s)" >&2
    
    # Output only the recipe paths to stdout (for readarray)
    printf '%s\n' "${terraform_recipes[@]}"
}

# ============================================================================
# Recipe Information Extraction
# ============================================================================

# Extracts metadata from a recipe file path
# Args: recipe file path
# Output: "root_folder resource_type platform_service file_name"
# Returns: 0 on success, 1 on failure
extract_recipe_info() {
    local recipe_file="$1"
    
    # Normalize path: remove leading ./ and make relative if absolute
    local path="${recipe_file#./}"
    
    # Parse using regex: RootFolder/ResourceType/recipes/Platform/terraform/*.tf
    if [[ "$path" =~ (^|.*/)([^/]+)/([^/]+)/recipes/([^/]+)/terraform/([^/]+)$ ]]; then
        local root_folder="${BASH_REMATCH[2]}"
        local resource_type="${BASH_REMATCH[3]}"
        local platform_service="${BASH_REMATCH[4]}"
        local file_name="${BASH_REMATCH[5]}"
        echo "$root_folder $resource_type $platform_service $file_name"
        return 0
    fi
    
    # If pattern doesn't match, return error
    echo "Error: Path doesn't match expected pattern: $path" >&2
    echo "Expected: <RootFolder>/<ResourceType>/recipes/<Platform>/terraform/*.tf" >&2
    return 1
}

# ============================================================================
# Recipe Packaging Functions
# ============================================================================

# Packages all recipes into ZIP archives
# Args: array of recipe file paths
# Creates temporary directories and ZIP files (stored in TMP_DIR)
create_recipe_zips() {
    local recipes=("$@")
    
    # Create temporary directory for organizing recipes
    TEMP_RECIPES_DIR=$(mktemp -d)
    echo "Using temporary directory for recipes: $TEMP_RECIPES_DIR"
    
    # Copy each recipe to temp dir with standardized name
    for recipe_file in "${recipes[@]}"; do
        read -r root_folder resource_type platform_service file_name <<< \
            "$(extract_recipe_info "$recipe_file")"
        
        # Validate extraction succeeded
        if [[ -z "$resource_type" || -z "$platform_service" ]]; then
            echo "Error: Failed to extract recipe info from: $recipe_file" >&2
            exit 1
        fi
        
        local recipe_dir
        recipe_dir=$(dirname "$recipe_file")
        local recipe_name="$resource_type-$platform_service"
        
        echo "Copying recipe from $recipe_dir to $TEMP_RECIPES_DIR/$recipe_name"
        cp -r "$recipe_dir" "$TEMP_RECIPES_DIR/$recipe_name"
    done
    
    # Create another temp directory for ZIP files
    TMP_DIR=$(mktemp -d)
    echo "Using temporary directory for ZIPs: $TMP_DIR"
    
    # Create ZIP files
    for recipe_dir in "$TEMP_RECIPES_DIR"/*/; do
        [[ -d "$recipe_dir" ]] || continue
        
        local recipe_name
        recipe_name=$(basename "$recipe_dir")
        local zip_file="$TMP_DIR/$recipe_name.zip"
        
        echo "Creating ZIP: $zip_file"
        if ! (cd "$recipe_dir" && zip -q -r "$zip_file" .); then
            echo "Error: Failed to create ZIP file: $zip_file" >&2
            exit 1
        fi
    done
    
    echo "Created ZIP files in: $TMP_DIR"
    ls -lh "$TMP_DIR"
}

# ============================================================================
# ConfigMap Publishing Functions
# ============================================================================

# Publishes ZIP files to a Kubernetes ConfigMap
# Args: namespace name, configmap name
# Deletes existing ConfigMap if present, then creates new one
publish_configmap() {
    local namespace="$1"
    local configmap_name="$2"
    local zip_dir="$TMP_DIR"
    
    # Build kubectl command arguments dynamically
    local kubectl_args=("kubectl" "create" "configmap" "$configmap_name" \
        "--namespace" "$namespace")
    
    # Add each ZIP file
    local recipe_count=0
    for zip_file in "$zip_dir"/*.zip; do
        [[ -f "$zip_file" ]] || continue
        
        local zip_name
        zip_name=$(basename "$zip_file")
        kubectl_args+=("--from-file=$zip_name=$zip_file")
        recipe_count=$((recipe_count + 1))
    done
    
    if [[ $recipe_count -eq 0 ]]; then
        echo "Error: No ZIP files found to publish" >&2
        exit 1
    fi
    
    echo "Publishing $recipe_count recipe(s) to ConfigMap: $namespace/$configmap_name"
    
    # Delete existing configmap if it exists (idempotent approach)
    if kubectl get configmap "$configmap_name" -n "$namespace" >/dev/null 2>&1; then
        echo "Deleting existing ConfigMap..."
        kubectl delete configmap "$configmap_name" --namespace "$namespace" >/dev/null 2>&1 || true
    fi
    
    # Create new configmap with all ZIP files
    if ! "${kubectl_args[@]}" >/dev/null 2>&1; then
        echo "Error: Failed to create ConfigMap" >&2
        # Show the actual error by running again without suppression
        "${kubectl_args[@]}"
        exit 1
    fi
    
    echo "Successfully created ConfigMap: $namespace/$configmap_name"
}

# ============================================================================
# Main Function
# ============================================================================

# Main execution flow: validates requirements, discovers recipes,
# packages them, publishes to ConfigMap, and deploys web server
main() {
    echo "============================================================================"
    echo "Terraform Recipe Publishing System"
    echo "============================================================================"
    
    # Validate prerequisites
    validate_requirements
    
    # Create namespace if it doesn't exist
    create_namespace "$TERRAFORM_MODULE_SERVER_NAMESPACE"
    
    # Find all Terraform recipes
    echo ""
    echo "============================================================================"
    echo "Finding Terraform Recipes"
    echo "============================================================================"
    readarray -t terraform_recipes < <(find_terraform_recipes)
    
    # Note: find_terraform_recipes exits if no recipes found, so this is unreachable
    # Keeping it for defensive programming in case function behavior changes
    
    # Package recipes into ZIP files
    echo ""
    echo "============================================================================"
    echo "Packaging Recipes"
    echo "============================================================================"
    create_recipe_zips "${terraform_recipes[@]}"
    
    # Publish to ConfigMap
    echo ""
    echo "============================================================================"
    echo "Publishing to ConfigMap"
    echo "============================================================================"
    publish_configmap "$TERRAFORM_MODULE_SERVER_NAMESPACE" \
        "$TERRAFORM_MODULE_CONFIGMAP_NAME"
    
    # Deploy web server
    echo ""
    echo "============================================================================"
    echo "Deploying Web Server"
    echo "============================================================================"
    deploy_web_server "$TERRAFORM_MODULE_SERVER_NAMESPACE"
    
    # Wait for deployment to be ready
    wait_for_deployment "$TERRAFORM_MODULE_SERVER_NAMESPACE" \
        "$TERRAFORM_MODULE_DEPLOYMENT_NAME"
    
    # Print access information
    echo ""
    echo "============================================================================"
    echo "Deployment Complete"
    echo "============================================================================"
    echo "Terraform module server is ready!"
    echo ""
    echo "Cluster-internal URLs (for Radius):"
    for zip_file in "$TMP_DIR"/*.zip; do
        [[ -f "$zip_file" ]] || continue
        local zip_name
        zip_name=$(basename "$zip_file")
        echo "  http://$TERRAFORM_MODULE_SERVICE_NAME.$TERRAFORM_MODULE_SERVER_NAMESPACE.svc.cluster.local/$zip_name"
    done
    echo ""
    echo "To test locally, run:"
    echo "  kubectl port-forward svc/$TERRAFORM_MODULE_SERVICE_NAME 8999:80 -n $TERRAFORM_MODULE_SERVER_NAMESPACE"
    echo ""
    echo "Then access recipes at:"
    for zip_file in "$TMP_DIR"/*.zip; do
        [[ -f "$zip_file" ]] || continue
        local zip_name
        zip_name=$(basename "$zip_file")
        echo "  http://localhost:8999/$zip_name"
    done
    echo ""
    
    log "✅ All Terraform recipes published and server ready"
}

# ============================================================================
# Script Entry Point
# ============================================================================

# Only execute main if script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
