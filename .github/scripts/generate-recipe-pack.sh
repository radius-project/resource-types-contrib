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
# Generate a Recipe Pack Bicep template from available recipes
#
# Usage: ./generate-recipe-pack.sh [repo-root] [pack-name] [output-file]
# Example: ./generate-recipe-pack.sh . biceprecipepack recipe-pack.bicep
# Example: ./generate-recipe-pack.sh . terraformrecipepack recipe-pack.bicep
# =============================================================================

set -euo pipefail

REPO_ROOT="${1:-$(pwd)}"
PACK_NAME="${2:-biceprecipepack}"
OUTPUT_FILE="${3:-recipe-pack.bicep}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKOUT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=.github/scripts/lib-recipe-platform-filter.sh
source "$SCRIPT_DIR/lib-recipe-platform-filter.sh"
rtc_parse_recipe_platform_filter

if [[ -n "${RTC_ACI_TEST_DESIRED_COUNT+x}" && "${RTC_ACI_TEST_DESIRED_COUNT}" != 1 ]]; then
    echo "Error: RTC_ACI_TEST_DESIRED_COUNT must be 1 when set." >&2
    exit 1
fi

# Determine recipe type from pack name
if [[ "$PACK_NAME" == *"terraform"* ]]; then
    RECIPE_TYPE="terraform"
    RECIPE_KIND="terraform"
else
    RECIPE_TYPE="bicep"
    RECIPE_KIND="bicep"
fi

echo "==> Generating recipe pack '$PACK_NAME' from $RECIPE_TYPE recipes in $REPO_ROOT"

# Find recipe directories based on type
if ! RECIPE_LIST="$("$SCRIPT_DIR"/list-recipe-folders.sh "$REPO_ROOT" "$RECIPE_TYPE")"; then
    echo "Error: Failed to discover recipes in '$REPO_ROOT'" >&2
    exit 1
fi
RECIPE_DIRS=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$RECIPE_TYPE" == "bicep" ]] && [[ "$line" == *"/bicep" ]] && ls "$line"/*.bicep &>/dev/null; then
        RECIPE_DIRS+=("$line")
    elif [[ "$RECIPE_TYPE" == "terraform" ]] && [[ "$line" == *"/terraform" ]] && [[ -f "$line/main.tf" ]]; then
        RECIPE_DIRS+=("$line")
    fi
done <<< "$RECIPE_LIST"

# Kubernetes clients need Kubernetes secrets, including model-generated API keys.
container_dependency="$CHECKOUT_ROOT/Compute/containers/recipes/kubernetes/bicep"
if [[ "$RECIPE_TYPE" == bicep && ${#RECIPE_DIRS[@]} -gt 0 ]] &&
    rtc_is_azure_test_dependency "$container_dependency"; then
    selected_recipes=()
    for recipe_dir in "${RECIPE_DIRS[@]}"; do
        # Keep one backend per type. Azure secrets have a separate CI test phase.
        if [[ "$recipe_dir" != */Security/secrets/recipes/*/bicep &&
              "$recipe_dir" != */Compute/containers/recipes/*/bicep ]]; then
            selected_recipes+=("$recipe_dir")
        fi
    done
    for dependency in Compute/containers Security/secrets; do
        dependency_dir="$CHECKOUT_ROOT/$dependency/recipes/kubernetes/bicep"
        if ! ls "$dependency_dir"/*.bicep &>/dev/null; then
            echo "Error: Kubernetes $dependency dependency not found in '$dependency_dir'." >&2
            exit 1
        fi
        selected_recipes+=("$(cd "$dependency_dir" && pwd)")
    done
    RECIPE_DIRS=("${selected_recipes[@]}")
fi

if [[ ${#RECIPE_DIRS[@]} -eq 0 ]]; then
    echo "==> No $RECIPE_TYPE recipes found"
    # Callers use output-file existence to decide whether to deploy a pack.
    if ! rm -f -- "$OUTPUT_FILE"; then
        echo "Error: Could not remove stale recipe pack output '$OUTPUT_FILE'" >&2
        exit 1
    fi
    exit 0
fi

echo "==> Found ${#RECIPE_DIRS[@]} $RECIPE_TYPE recipe(s)"

# Start building the Bicep template
cat > "$OUTPUT_FILE" << EOF
extension radius

EOF
if [[ "$RECIPE_TYPE" == bicep ]]; then
    for recipe_dir in "${RECIPE_DIRS[@]}"; do
        if [[ "$recipe_dir" == */Data/mongoDatabases/recipes/kubernetes/bicep ]]; then
            cat >> "$OUTPUT_FILE" <<'EOF'
@description('Stable MongoDB password. Reuse this value when deploying this pack again with existing database volumes.')
@secure()
@minLength(16)
param mongoPassword string = newGuid()

EOF
            break
        fi
    done
fi
cat >> "$OUTPUT_FILE" << EOF
resource PACK_NAME_PLACEHOLDER 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'PACK_NAME_PLACEHOLDER'
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
    
    # Extract platform and language from path (e.g., recipes/kubernetes/bicep -> kubernetes/bicep)
    RECIPES_SUBPATH="${recipe_dir#*recipes/}"
    
    # Build template path based on recipe type
    CATEGORY_LOWER=$(echo "$CATEGORY" | tr '[:upper:]' '[:lower:]')
    RESOURCE_LOWER=$(echo "$RESOURCE_NAME" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$RECIPE_TYPE" == "bicep" ]]; then
        # Find the .bicep file in the recipe directory
        BICEP_FILES=("$recipe_dir"/*.bicep)
        BICEP_FILE="${BICEP_FILES[0]}"
        RECIPE_FILENAME=$(basename "$BICEP_FILE" .bicep)
        # OCI registry path for bicep recipes
        TEMPLATE_PATH="reciperegistry:5000/radius-recipes/${CATEGORY_LOWER}/${RESOURCE_LOWER}/${RECIPES_SUBPATH}/${RECIPE_FILENAME}:latest"
    else
        # For terraform, use cluster-internal HTTP URL to module server
        # Recipe name format: {RESOURCE_TYPE}-{PLATFORM} (e.g., postgreSqlDatabases-kubernetes)
        PLATFORM=$(basename "$(dirname "$recipe_dir")")  # Extract platform (e.g., kubernetes)
        RECIPE_NAME="${RESOURCE_NAME}-${PLATFORM}"
        TEMPLATE_PATH="http://tf-module-server.radius-test-tf-module-server.svc.cluster.local/${RECIPE_NAME}.zip"
    fi
    
    echo "==> Adding recipe: $RESOURCE_TYPE -> $TEMPLATE_PATH"
    
    # Add recipe entry to the template
    cat >> "$OUTPUT_FILE" << EOF
      '$RESOURCE_TYPE': {
        kind: '$RECIPE_KIND'
        source: '$TEMPLATE_PATH'
        plainHttp: true
EOF
    if [[ "$RECIPE_TYPE" == bicep && "$RESOURCE_TYPE" == Radius.Data/mongoDatabases &&
          "$RECIPES_SUBPATH" == kubernetes/bicep ]]; then
        cat >> "$OUTPUT_FILE" <<'EOF'
        parameters: {
          mongoPassword: mongoPassword
        }
EOF
    fi
    if [[ "${RTC_ACI_TEST_DESIRED_COUNT:-}" == 1 &&
          "$RESOURCE_TYPE" == Radius.Compute/containers && "$RECIPES_SUBPATH" == azure/bicep ]]; then
        cat >> "$OUTPUT_FILE" <<'EOF'
        parameters: {
          desiredCount: 1
        }
EOF
    fi
    echo "      }" >> "$OUTPUT_FILE"
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