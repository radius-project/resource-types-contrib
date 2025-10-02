#!/bin/bash

# =============================================================================
# Find and test all Radius recipes in the repository by calling test-recipe.sh
# for each discovered recipe directory.
# =============================================================================

set -euo pipefail

REPO_ROOT="${1:-$(pwd)}"

echo "==> Finding all recipes in $REPO_ROOT"

# Find all recipe directories (both bicep and terraform)
RECIPE_DIRS=()

# Find Bicep recipes (directories containing .bicep files under recipes/)
while IFS= read -r -d '' dir; do
    RECIPE_DIRS+=("$dir")
done < <(find "$REPO_ROOT" -type d -path "*/recipes/*/*" -exec sh -c 'ls "$1"/*.bicep >/dev/null 2>&1' _ {} \; -print0)

# Find Terraform recipes (directories containing main.tf under recipes/)
while IFS= read -r -d '' dir; do
    RECIPE_DIRS+=("$dir")
done < <(find "$REPO_ROOT" -type d -path "*/recipes/*/*" -exec test -f {}/main.tf \; -print0)

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
