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
# Find and test all Radius recipes in the repository by calling test-recipe.sh
# for each discovered recipe directory.
# =============================================================================

set -euo pipefail

REPO_ROOT="${1:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Finding all recipes in $REPO_ROOT"

mapfile -t RECIPE_DIRS < <("$SCRIPT_DIR"/list-recipe-folders.sh "$REPO_ROOT")

if [[ ${#RECIPE_DIRS[@]} -eq 0 ]]; then
    echo "==> No recipes found"
    exit 0
fi

echo "==> Found ${#RECIPE_DIRS[@]} recipe(s) to test"

FAILED_RECIPES=()
PASSED_RECIPES=()

# Test each recipe
for recipe_dir in "${RECIPE_DIRS[@]}"; do
    # Convert to relative path for cleaner output
    RELATIVE_PATH="${recipe_dir#$REPO_ROOT/}"
    echo ""
    echo "================================================"
    echo "Testing: $RELATIVE_PATH"
    echo "================================================"
    
    if ./.github/scripts/test-recipe.sh "$recipe_dir"; then
        PASSED_RECIPES+=("$RELATIVE_PATH")
    else
        FAILED_RECIPES+=("$RELATIVE_PATH")
    fi
done

# Print summary
echo ""
echo "================================================"
echo "Test Summary"
echo "================================================"
echo "Passed: ${#PASSED_RECIPES[@]}"
echo "Failed: ${#FAILED_RECIPES[@]}"

if [[ ${#FAILED_RECIPES[@]} -gt 0 ]]; then
    echo ""
    echo "Failed recipes:"
    for recipe in "${FAILED_RECIPES[@]}"; do
        echo "  - $recipe"
    done
    exit 1
fi

echo ""
echo "==> All recipes passed!"
