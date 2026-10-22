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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-recipe-packs.sh
source "$SCRIPT_DIR/lib-recipe-packs.sh"

if [[ $# -ne 2 || "$1" == "$2" ]]; then
    echo "Usage: $0 <checked-in-pack.bicep> <temporary-pack.bicep>" >&2
    exit 1
fi

template="$1"
output="$2"
mappings="$(mktemp "${TMPDIR:-/tmp}/rtc-local-recipes-XXXXXX")"
trap 'rm -f -- "$mappings"' EXIT
entries="$(rtc_recipe_pack_entries "$template")"

while IFS=$'\t' read -r resource_type source; do
    [[ -z "$resource_type" ]] && continue
    [[ "$source" == "$RTC_REPO_RECIPE_SOURCE_PREFIX"* ]] || continue

    case "$source" in
        ghcr.io/radius-project/kube-recipes/*) platform=kubernetes ;;
        ghcr.io/radius-project/azure-aci-recipes/*) platform=azure ;;
        *)
            echo "Error: no local recipe mapping for '$source'." >&2
            exit 1
            ;;
    esac

    resource_dir="$(rtc_resource_type_dir_for_entry "$resource_type")"
    artifact="${source##*/}"
    artifact="${artifact%%[:@]*}"
    type_name="${resource_dir##*/}"
    if [[ "$artifact" != "${type_name,,}" ]]; then
        echo "Error: source '$source' does not match '$resource_type'." >&2
        exit 1
    fi
    entry_body="$(rtc_recipe_pack_entry_body "$template" "$resource_type")"
    if ! grep -qE "^[[:space:]]*kind: 'bicep'[[:space:]]*$" <<<"$entry_body"; then
        echo "Error: local source '$source' must use kind 'bicep'." >&2
        exit 1
    fi

    recipe_dir="$RTC_REPO_ROOT/$resource_dir/recipes/$platform/bicep"
    if [[ ! -d "$recipe_dir" ]]; then
        echo "Error: local recipe directory '$recipe_dir' does not exist." >&2
        exit 1
    fi
    recipe_files="$(find "$recipe_dir" -maxdepth 1 -type f -name '*.bicep' | sort)"
    if [[ -z "$recipe_files" || "$recipe_files" == *$'\n'* ]]; then
        echo "Error: expected exactly one Bicep recipe in '$recipe_dir'." >&2
        exit 1
    fi

    recipe_relpath="$resource_dir/recipes/$platform/bicep/$(basename "$recipe_files")"
    if [[ ! "$recipe_relpath" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        echo "Error: unsupported local recipe path '$recipe_relpath'." >&2
        exit 1
    fi
    # Use the same local registry path as build-bicep-recipe.sh.
    local_source="reciperegistry:5000/radius-recipes/$resource_dir/$platform/bicep/$(basename "$recipe_files" .bicep):latest"
    local_source="${local_source,,}"
    (
        cd "$RTC_REPO_ROOT"
        bash "$SCRIPT_DIR/build-bicep-recipe.sh" "$recipe_files"
    )
    printf '%s\t%s\t%s\n' "$resource_type" "$source" "$local_source" >>"$mappings"
done <<<"$entries"

# Change only the entry source and its transport. Keep parameters, outputs,
# expressions, external module versions, and the original pack file unchanged.
awk -F '\t' '
    FILENAME == ARGV[1] {
        original[$1] = $2
        replacement[$1] = $3
        expected++
        next
    }
    /^[[:space:]]*\047Radius\.[A-Za-z0-9]+\/[A-Za-z0-9]+\047:[[:space:]]*\{/ {
        match($0, /^[[:space:]]*/)
        property_indent = RLENGTH + 2
        match($0, /Radius\.[A-Za-z0-9]+\/[A-Za-z0-9]+/)
        entry = substr($0, RSTART, RLENGTH)
    }
    entry in replacement && /^[[:space:]]*source:[[:space:]]*\047/ {
        match($0, /^[[:space:]]*/)
        if (RLENGTH != property_indent) { print; next }
        match($0, /\047[^\047]*\047/)
        actual = substr($0, RSTART + 1, RLENGTH - 2)
        if (actual != original[entry]) {
            print "Error: unexpected source in " entry > "/dev/stderr"
            exit 1
        }
        sub(/\047[^\047]*\047/, "\047" replacement[entry] "\047")
        print
        print substr($0, 1, property_indent) "plainHttp: true"
        changed++
        next
    }
    entry in replacement && /^[[:space:]]*plainHttp:/ {
        match($0, /^[[:space:]]*/)
        if (RLENGTH == property_indent) next
    }
    { print }
    END {
        if (changed != expected) {
            print "Error: not all local recipe sources were replaced." > "/dev/stderr"
            exit 1
        }
    }
' "$mappings" "$template" >"$output"
