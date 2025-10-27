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
# Register all Radius recipes in the repository by calling register-recipe.sh
# for each discovered recipe directory. This should be run after building all
# recipes but before testing them.
#
# Usage: ./register-all-recipes.sh [repo-root] [environment] [recipe-type]
# Example: ./register-all-recipes.sh . bicep-test bicep
# Example: ./register-all-recipes.sh . terraform-test terraform
# =============================================================================

set -euo pipefail

REPO_ROOT="${1:-$(pwd)}"
ENVIRONMENT="${2:-default}"
RECIPE_TYPE="${3:-all}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Finding $RECIPE_TYPE recipes in $REPO_ROOT for environment $ENVIRONMENT"

# Use while read loop for better compatibility (mapfile requires bash 4+)
RECIPE_DIRS=()
while IFS= read -r line; do
    # Filter by recipe type if specified
    if [[ "$RECIPE_TYPE" == "all" ]]; then
        RECIPE_DIRS+=("$line")
    elif [[ "$RECIPE_TYPE" == "bicep" ]] && [[ "$line" == *"/bicep" ]] && ls "$line"/*.bicep &>/dev/null; then
        RECIPE_DIRS+=("$line")
    elif [[ "$RECIPE_TYPE" == "terraform" ]] && [[ "$line" == *"/terraform" ]] && [[ -f "$line/main.tf" ]]; then
        RECIPE_DIRS+=("$line")
    fi
done < <("$SCRIPT_DIR"/list-recipe-folders.sh "$REPO_ROOT" "$RECIPE_TYPE")

if [[ ${#RECIPE_DIRS[@]} -eq 0 ]]; then
    echo "==> No $RECIPE_TYPE recipes found"
    exit 0
fi

echo "==> Found ${#RECIPE_DIRS[@]} $RECIPE_TYPE recipe(s) to register"

FAILED_RECIPES=()
PASSED_RECIPES=()

# Register each recipe
for recipe_dir in "${RECIPE_DIRS[@]}"; do
    # Convert to relative path for cleaner output
    RELATIVE_PATH="${recipe_dir#$REPO_ROOT/}"
    echo ""
    echo "================================================"
    echo "Registering: $RELATIVE_PATH"
    echo "================================================"
    
    if ./.github/scripts/register-recipe.sh "$recipe_dir" "$ENVIRONMENT"; then
        PASSED_RECIPES+=("$RELATIVE_PATH")
    else
        FAILED_RECIPES+=("$RELATIVE_PATH")
    fi
done

# Print summary
echo ""
echo "================================================"
echo "Registration Summary"
echo "================================================"
echo "Passed: ${#PASSED_RECIPES[@]}"
echo "Failed: ${#FAILED_RECIPES[@]}"

if [[ ${#FAILED_RECIPES[@]} -gt 0 ]]; then
    echo ""
    echo "Failed recipe registrations:"
    for recipe in "${FAILED_RECIPES[@]}"; do
        echo "  - $recipe"
    done
    exit 1
fi

echo ""
echo "==> All recipes registered successfully!"

# Log all registered recipes
echo ""
echo "================================================"
echo "Currently Registered Recipes"  
echo "================================================"
rad recipe list --environment "$ENVIRONMENT" || echo "Warning: Could not list registered recipes"