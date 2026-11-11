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
# build-all.sh
# -----------------------------------------------------------------------------
# Build all resource types and their associated Bicep and Terraform recipes.
#
# Behavior:
# - Discovers resource type folders using list-resource-type-folders.sh
#   (optionally scoped to a provided root directory argument).
# - For each resource type folder, runs `make build-resource-type`.
# - For each Bicep file found under <resource>/recipes/**/<name>.bicep,
#   runs `make build-bicep-recipe`.
# - For each Terraform directory found under <resource>/recipes/**/terraform/,
#   runs `make build-terraform-recipe`.
#
# Usage:
#   ./build-all.sh [ROOT_DIR]
# If ROOT_DIR is omitted, discovery defaults to the current working directory.
# =============================================================================

set -euo pipefail

ROOT_DIR="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-recipe-platform-filter.sh
source "$SCRIPT_DIR/lib-recipe-platform-filter.sh"
rtc_parse_recipe_platform_filter

should_include_platform() {
    local recipe_path="$1"

    # Extract segment after recipes/ (path is relative: recipes/platform/...)
    # Remove "recipes/" prefix if present
    local rel="${recipe_path#recipes/}"
    # Get the first path segment (the platform)
    local platform="${rel%%/*}"

    rtc_matches_recipe_platform "$platform"
}

# Iterate over all resource type folders
if ! TYPE_DIRS="$(./.github/scripts/list-resource-type-folders.sh ${ROOT_DIR:+"$ROOT_DIR"})"; then
    echo "Error: Failed to discover resource types" >&2
    exit 1
fi
while IFS= read -r type_dir; do
    [[ -z "$type_dir" ]] && continue

    make -s build-resource-type TYPE_FOLDER="$type_dir"

    # Build/publish all Bicep recipes under this resource type, if any
    recipes_root="$type_dir/recipes"
    if [[ -d "$recipes_root" ]]; then
        # Keep the producer PID so EOF does not hide a failed scan.
        exec 3< <(find "$recipes_root" -type f -name '*.bicep' -print0)
        scan_pid=$!
        while IFS= read -r -d '' recipe_file; do
            recipe_rel_path="${recipe_file#"$type_dir"/}"
            if should_include_platform "$recipe_rel_path" || rtc_is_azure_test_container_dependency "$recipe_file"; then
                echo "Building Bicep recipe: $recipe_file"
                make -s build-bicep-recipe RECIPE_PATH="$recipe_file"
            else
                echo "Skipping Bicep recipe (platform filter): $recipe_file"
            fi
        done <&3
        exec 3<&-
        if ! wait "$scan_pid"; then
            echo "Error: Failed to scan Bicep recipes in '$recipes_root'" >&2
            exit 1
        fi
    fi

    # Build/publish all Terraform recipes under this resource type, if any
    if [[ -d "$recipes_root" ]]; then
        exec 3< <(find "$recipes_root" -type d -name 'terraform' -print0)
        scan_pid=$!
        while IFS= read -r -d '' recipe_dir; do
            recipe_rel_path="${recipe_dir#"$type_dir"/}"
            if should_include_platform "$recipe_rel_path"; then
                echo "Building Terraform recipe: $recipe_dir"
                make -s build-terraform-recipe RECIPE_PATH="$recipe_dir"
            else
                echo "Skipping Terraform recipe (platform filter): $recipe_dir"
            fi
        done <&3
        exec 3<&-
        if ! wait "$scan_pid"; then
            echo "Error: Failed to scan Terraform recipes in '$recipes_root'" >&2
            exit 1
        fi
    fi
done <<< "$TYPE_DIRS"
