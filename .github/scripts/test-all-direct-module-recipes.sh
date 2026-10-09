#!/bin/bash

# ------------------------------------------------------------
# Copyright 2026 The Radius Authors.
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
# Runs test-direct-module-recipe.sh for every direct-module Resource Type
# across every checked-in Recipe Pack targeting a platform group. This is the
# driver the nightly workflow (Layer 3 of issue #312) uses: it assumes
# deploy-all-checked-in-recipe-packs.sh has already deployed that group's
# packs. Each pack is activated before its mappings are tested.
#
# A type in two packs is tested twice: each pack can use a different mapping.
#
# Usage: ./test-all-direct-module-recipes.sh <platform-group> [workspace] [environment]
# Example: ./test-all-direct-module-recipes.sh azure default default
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-recipe-packs.sh
source "$SCRIPT_DIR/lib-recipe-packs.sh"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <platform-group> [workspace] [environment]" >&2
    exit 1
fi

platform_group="$1"
workspace_name="${2:-default}"
environment_name="${3:-default}"

pack_list="$(rtc_recipe_packs_for_platform_group "$platform_group")"
packs=()
if [[ -n "$pack_list" ]]; then
    mapfile -t packs <<<"$pack_list"
fi

if [[ ${#packs[@]} -eq 0 ]]; then
    echo "No checked-in recipe packs target platform group '$platform_group'; nothing to test."
    exit 0
fi

failures=0
tested=0

for pack_id in "${packs[@]}"; do
    direct_types="$(rtc_list_direct_module_types "$pack_id")"
    [[ -z "$direct_types" ]] && continue
    template="$(rtc_recipe_pack_template "$pack_id")"
    pack_name="$(rtc_recipe_pack_name "$template")"
    if [[ -z "$pack_name" ]]; then
        echo "Error: could not determine the recipe pack name in $template." >&2
        exit 1
    fi
    rad env update "$environment_name" --workspace "$workspace_name" --recipe-packs "$pack_name" --preview

    while IFS= read -r resource_type_dir; do
        [[ -z "$resource_type_dir" ]] && continue
        tested=$((tested + 1))

        echo "=============================================================="
        echo "==> Direct-module test: $resource_type_dir (from pack '$pack_id')"
        echo "=============================================================="
        if ! "$SCRIPT_DIR/test-direct-module-recipe.sh" "$resource_type_dir" "$workspace_name" "$environment_name"; then
            echo "==> FAILED: $resource_type_dir" >&2
            failures=$((failures + 1))
        fi
    done <<<"$direct_types"
done

echo "=============================================================="
echo "==> Direct-module tests complete: $tested tested, $failures failed"
echo "=============================================================="

if [[ "$tested" -eq 0 ]]; then
    echo "No direct-module Resource Types with test apps found for platform group '$platform_group'."
fi

[[ "$failures" -eq 0 ]]
