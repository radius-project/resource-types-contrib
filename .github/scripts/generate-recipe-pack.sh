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
# Generate a Recipe Pack Bicep template from all available Bicep recipes
#
# Usage: ./generate-recipe-pack.sh [repo-root] [pack-name] [output-file]
# Example: ./generate-recipe-pack.sh . kuberecipepack recipe-pack.bicep
# =============================================================================

set -euo pipefail

REPO_ROOT="${1:-$(pwd)}"
PACK_NAME="${2:-kuberecipepack}"
OUTPUT_FILE="${3:-recipe-pack.bicep}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Generating recipe pack '$PACK_NAME' from Bicep recipes in $REPO_ROOT"

# Find all Bicep recipe directories
RECIPE_DIRS=()
while IFS= read -r line; do
    if [[ "$line" == *"/bicep" ]] && ls "$line"/*.bicep &>/dev/null; then
        RECIPE_DIRS+=("$line")
    fi
done < <("$SCRIPT_DIR"/list-recipe-folders.sh "$REPO_ROOT" "bicep")

if [[ ${#RECIPE_DIRS[@]} -eq 0 ]]; then
    echo "==> No Bicep recipes found"
    exit 1
fi

echo "==> Found ${#RECIPE_DIRS[@]} Bicep recipe(s)"

# Start building the Bicep template
cat > "$OUTPUT_FILE" << 'EOF'
extension radius

resource biceprecipepack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'biceprecipepack'
  location: 'global'
  properties: {
    recipes: {
EOF

# Process each recipe directory
for recipe_dir in "${RECIPE_DIRS[@]}"; do
    # Extract resource type from path
    RESOURCE_TYPE_PATH=$(echo "$recipe_dir" | sed -E 's|/recipes/.*||')
    CATEGORY=$(basename "$(dirname "$RESOURCE_TYPE_PATH")")
    RESOURCE_NAME=$(basename "$RESOURCE_TYPE_PATH")
    RESOURCE_TYPE="Radius.$CATEGORY/$RESOURCE_NAME"
    
    # Find the .bicep file in the recipe directory
    BICEP_FILE=$(ls "$recipe_dir"/*.bicep 2>/dev/null | head -n 1)
    RECIPE_FILENAME=$(basename "$BICEP_FILE" .bicep)
    
    # Extract platform and language from path (e.g., recipes/kubernetes/bicep -> kubernetes/bicep)
    RECIPES_SUBPATH="${recipe_dir#*recipes/}"
    
    # Build OCI path
    CATEGORY_LOWER=$(echo "$CATEGORY" | tr '[:upper:]' '[:lower:]')
    RESOURCE_LOWER=$(echo "$RESOURCE_NAME" | tr '[:upper:]' '[:lower:]')
    TEMPLATE_PATH="reciperegistry:5000/radius-recipes/${CATEGORY_LOWER}/${RESOURCE_LOWER}/${RECIPES_SUBPATH}/${RECIPE_FILENAME}:latest"
    
    echo "==> Adding recipe: $RESOURCE_TYPE -> $TEMPLATE_PATH"
    
    # Add recipe entry to the template
    cat >> "$OUTPUT_FILE" << EOF
      '$RESOURCE_TYPE': {
        recipeKind: 'bicep'
        recipeLocation: '$TEMPLATE_PATH'
        plainHttp: true
      }
EOF
done

# Close the Bicep template
cat >> "$OUTPUT_FILE" << 'EOF'
    }
  }
}
EOF

# Replace the placeholder with the actual pack name
sed -i.bak "s/PACK_NAME_PLACEHOLDER/$PACK_NAME/g" "$OUTPUT_FILE"
rm -f "$OUTPUT_FILE.bak"

echo "==> Recipe pack template generated: $OUTPUT_FILE"
echo "==> Pack name: $PACK_NAME"
echo "==> Contains ${#RECIPE_DIRS[@]} recipe(s)"