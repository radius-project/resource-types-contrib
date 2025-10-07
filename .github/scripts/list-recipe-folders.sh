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

if [[ ! -d "$ROOT_DIR" ]]; then
    echo "Error: Root directory '$ROOT_DIR' does not exist" >&2
    exit 1
fi

# Convert ROOT_DIR to an absolute path
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

declare -A RECIPE_DIRS=()

find_recipe_dirs() {
    local -a find_expression=("$@")

    while IFS= read -r -d '' matched_path; do
        local dir
        dir="$(dirname "$matched_path")"
        RECIPE_DIRS["$dir"]=1
    done < <(find "$ROOT_DIR" "${find_expression[@]}" -print0 2>/dev/null)
}

# Collect Bicep recipe directories (directories containing .bicep files under recipes/)
find_recipe_dirs -type f -path "*/recipes/*/*.bicep"

# Collect Terraform recipe directories (directories containing main.tf under recipes/terraform)
find_recipe_dirs -type f -path "*/recipes/*/terraform/main.tf"

if [[ ${#RECIPE_DIRS[@]} -eq 0 ]]; then
    exit 0
fi

printf '%s\n' "${!RECIPE_DIRS[@]}" | sort
