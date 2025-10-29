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
PLATFORM_FILTER_RAW="${RECIPE_PLATFORM_FILTER:-}"

declare -a PLATFORM_FILTERS=()
if [[ -n "$PLATFORM_FILTER_RAW" ]]; then
    IFS=',' read -ra _raw_filters <<< "$PLATFORM_FILTER_RAW"
    for _entry in "${_raw_filters[@]}"; do
        _trimmed="$(printf '%s' "$_entry" | xargs)"
        if [[ -n "$_trimmed" ]]; then
            PLATFORM_FILTERS+=("$_trimmed")
        fi
    done
fi

should_include_platform() {
    local recipe_path="$1"
    if [[ ${#PLATFORM_FILTERS[@]} -eq 0 ]]; then
        return 0
    fi

    # Extract segment after /recipes/
    local rel="${recipe_path#*/recipes/}"
    local platform="${rel%%/*}"

    for _filter in "${PLATFORM_FILTERS[@]}"; do
        if [[ "$platform" == "$_filter" ]]; then
            return 0
        fi
    done

    return 1
}

# Iterate over all resource type folders
while IFS= read -r type_dir; do
    [[ -z "$type_dir" ]] && continue

    make -s build-resource-type TYPE_FOLDER="$type_dir"

    # Build/publish all Bicep recipes under this resource type, if any
    recipes_root="$type_dir/recipes"
    if [[ -d "$recipes_root" ]]; then
        while IFS= read -r -d '' recipe_file; do
            if should_include_platform "${recipe_file#$type_dir/}"; then
                make -s build-bicep-recipe RECIPE_PATH="$recipe_file"
            fi
        done < <(find "$recipes_root" -type f -name '*.bicep' -print0)
    fi

    # Build/publish all Terraform recipes under this resource type, if any
    if [[ -d "$recipes_root" ]]; then
        while IFS= read -r -d '' recipe_dir; do
            if should_include_platform "${recipe_dir#$type_dir/}"; then
                make -s build-terraform-recipe RECIPE_PATH="$recipe_dir"
            fi
        done < <(find "$recipes_root" -type d -name 'terraform' -print0)
    fi
done < <(./.github/scripts/list-resource-type-folders.sh ${ROOT_DIR:+"$ROOT_DIR"})
