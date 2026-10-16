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
# Tests every runnable entry in every checked-in Recipe Pack for a platform
# group. Each pack is activated before its entries are deployed.
#
# Entries without test/app.bicep are reported. A pack with no runnable entries
# fails so nightly cannot report success without exercising that pack.
#
# Usage: ./test-all-recipe-pack-entries.sh <platform-group> [workspace] [environment]
# Example: ./test-all-recipe-pack-entries.sh azure default default
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
    echo "Error: no checked-in Recipe Packs target platform group '$platform_group'." >&2
    exit 1
fi

failures=0
tested=0
skipped=0
empty_packs=0

for pack_id in "${packs[@]}"; do
    resource_types="$(rtc_list_recipe_pack_types "$pack_id")"
    template="$(rtc_recipe_pack_template "$pack_id")"
    pack_name="$(rtc_recipe_pack_name "$template")"
    if [[ -z "$pack_name" ]]; then
        echo "Error: could not determine the Recipe Pack name in $template." >&2
        exit 1
    fi

    rad env update "$environment_name" --workspace "$workspace_name" --recipe-packs "$pack_name"
    pack_tested=0

    while IFS= read -r resource_type_dir; do
        [[ -z "$resource_type_dir" ]] && continue
        if [[ ! -f "$resource_type_dir/test/app.bicep" ]]; then
            echo "==> SKIPPED: $resource_type_dir from pack '$pack_id' has no test/app.bicep"
            skipped=$((skipped + 1))
            continue
        fi

        tested=$((tested + 1))
        pack_tested=$((pack_tested + 1))

        echo "=============================================================="
        echo "==> Recipe Pack entry test: $resource_type_dir (from pack '$pack_id')"
        echo "=============================================================="
        if ! "$SCRIPT_DIR/test-recipe-pack-entry.sh" "$resource_type_dir" "$workspace_name" "$environment_name"; then
            echo "==> FAILED: $resource_type_dir (from pack '$pack_id')" >&2
            failures=$((failures + 1))
        fi
    done <<<"$resource_types"

    if [[ "$pack_tested" -eq 0 ]]; then
        echo "Error: Recipe Pack '$pack_id' has no entries with test applications." >&2
        empty_packs=$((empty_packs + 1))
    fi
done

echo "=============================================================="
echo "==> Recipe Pack entry tests complete: $tested tested, $skipped skipped, $failures failed"
echo "=============================================================="

[[ "$tested" -gt 0 && "$failures" -eq 0 && "$empty_packs" -eq 0 ]]
