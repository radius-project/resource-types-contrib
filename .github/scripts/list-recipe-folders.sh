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
# list-recipe-folders.sh
# -----------------------------------------------------------------------------
# Find all directories that contain recipes (Bicep or Terraform).
# Lists both Bicep recipe directories (containing .bicep files) and Terraform
# recipe directories (named 'terraform' with main.tf).
#
# Usage:
#   ./list-recipe-folders.sh [ROOT_DIR]
# If ROOT_DIR is omitted, defaults to the current working directory.
# =============================================================================

set -euo pipefail

ROOT_DIR="${1:-$(pwd)}"
RECIPE_TYPE_FILTER="${2:-all}"
RECIPE_TYPE_FILTER="$(echo "$RECIPE_TYPE_FILTER" | tr '[:upper:]' '[:lower:]')"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-recipe-platform-filter.sh
source "$SCRIPT_DIR/lib-recipe-platform-filter.sh"

if [[ ! -d "$ROOT_DIR" ]]; then
    echo "Error: Root directory '$ROOT_DIR' does not exist" >&2
    exit 1
fi

# Convert ROOT_DIR to an absolute path
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

# Validate recipe type filter
case "$RECIPE_TYPE_FILTER" in
    all|bicep|terraform)
        ;;
    *)
        echo "Error: Unsupported recipe type filter '$RECIPE_TYPE_FILTER'. Expected 'bicep', 'terraform', or 'all'." >&2
        exit 1
        ;;
esac

rtc_parse_recipe_platform_filter

should_include_type() {
    local recipe_type="$1"
    case "$RECIPE_TYPE_FILTER" in
        all)
            return 0
            ;;
        bicep)
            [[ "$recipe_type" == "bicep" ]]
            return
            ;;
        terraform)
            [[ "$recipe_type" == "terraform" ]]
            return
            ;;
    esac
}

add_recipe_dir() {
    local dir="$1"
    local recipe_type="$2"

    if ! should_include_type "$recipe_type"; then
        return
    fi

    local platform=""
    if [[ "$dir" =~ /recipes/([^/]+)/ ]]; then
        platform="${BASH_REMATCH[1]}"
    fi
    if ! rtc_matches_recipe_platform "$platform"; then
        return
    fi

    RECIPE_DIRS+=("$dir")
}

# Use a regular array and sort/uniq instead of associative array for bash 3.x compatibility
RECIPE_DIRS=()

# Find Bicep recipe directories (directories containing .bicep files under recipes/)
if [[ "$RECIPE_TYPE_FILTER" == "all" || "$RECIPE_TYPE_FILTER" == "bicep" ]]; then
    while IFS= read -r -d '' matched_path; do
        add_recipe_dir "$(dirname "$matched_path")" "bicep"
    done < <(find "$ROOT_DIR" -type f -path "*/recipes/*/*.bicep" -print0 2>/dev/null)
fi

# Find Terraform recipe directories (directories containing main.tf under recipes/terraform)
if [[ "$RECIPE_TYPE_FILTER" == "all" || "$RECIPE_TYPE_FILTER" == "terraform" ]]; then
    while IFS= read -r -d '' matched_path; do
        add_recipe_dir "$(dirname "$matched_path")" "terraform"
    done < <(find "$ROOT_DIR" -type f -path "*/recipes/*/terraform/main.tf" -print0 2>/dev/null)
fi

if [[ ${#RECIPE_DIRS[@]} -eq 0 ]]; then
    exit 0
fi

# Remove duplicates and sort
printf '%s\n' "${RECIPE_DIRS[@]}" | sort -u
