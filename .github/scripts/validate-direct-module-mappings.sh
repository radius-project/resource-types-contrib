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

# Statically checks every "direct module" entry (see lib-recipe-packs.sh) in
# every checked-in Recipe Pack, with no deployment and no cloud cost. This is
# the "Layer 2" check from issue #312: real-infrastructure testing of these
# same entries happens separately (nightly, see test-direct-module-recipe.sh)
# because it costs real money. These checks run on every PR:
#
#   1. Every `{{context.resource.properties.<name>}}` expression in the entry
#      refers to a property that actually exists on that Resource Type.
#      Catches a typo'd or renamed property name.
#   2. For a property with a declared `enum` (e.g. `tls: [required, optional]`)
#      that an expression compares with a string literal (`==`), the literal
#      must be a declared enum value. Several values can share an else branch.
# This does not validate target module parameter names, shapes, or results.
#
# New pack, new direct-module entry, or new enum value? Nothing to update
# here -- rtc_list_direct_module_types() (lib-recipe-packs.sh) discovers it
# and this script re-derives everything else from the pack Bicep and the
# Resource Type's own YAML schema.
#
# Usage: validate-direct-module-mappings.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-recipe-packs.sh
source "$SCRIPT_DIR/lib-recipe-packs.sh"

exit_code=0
checked_count=0

# Print the top-level schema property names declared for a Resource Type's
# YAML manifest, one per line. Relies on the repo-wide convention of a single
# `schema: -> properties:` block per manifest (see postgreSqlDatabases.yaml
# for a representative example): keys are 2 spaces deeper than `properties:`
# and the block ends at the first line back at or above that indent.
schema_property_names() {
    local yaml_file="$1"
    awk '
        !found_schema && /^[[:space:]]*schema:[[:space:]]*$/ { found_schema = 1; next }
        found_schema && !found_props && /^[[:space:]]+properties:[[:space:]]*$/ {
            match($0, /^[[:space:]]*/)
            indent = RLENGTH
            found_props = 1
            next
        }
        found_props {
            match($0, /^[[:space:]]*/)
            cur_indent = RLENGTH
            if (cur_indent <= indent) { found_props = 0; next }
            if (cur_indent == indent + 2 && $0 ~ /^[[:space:]]+[A-Za-z0-9_]+:[[:space:]]*$/) {
                match($0, /[A-Za-z0-9_]+:/)
                print substr($0, RSTART, RLENGTH - 1)
            }
        }
    ' "$yaml_file" 2>/dev/null
}

# Print the declared enum values (unquoted, one per line) for one property in
# a Resource Type's YAML manifest, if any.
schema_property_enum_values() {
    local yaml_file="$1" property_name="$2"
    awk -v want="$property_name" '
        !found_prop && $0 ~ ("^[[:space:]]+" want ":[[:space:]]*$") {
            match($0, /^[[:space:]]*/)
            indent = RLENGTH
            found_prop = 1
            next
        }
        found_prop {
            match($0, /^[[:space:]]*/)
            cur_indent = RLENGTH
            if (cur_indent <= indent) { exit }
            if ($0 ~ /^[[:space:]]*enum:/) {
                print
                exit
            }
        }
    ' "$yaml_file" 2>/dev/null |
        grep -oE "'[^']*'|\"[^\"]*\"" |
        sed -E "s/^['\"]//; s/['\"]\$//"
}

yaml_file_for_resource_type() {
    local resource_type_dir="$1" type_name
    type_name="${resource_type_dir##*/}"
    echo "$RTC_REPO_ROOT/$resource_type_dir/${type_name}.yaml"
}

check_entry() {
    local pack_id="$1" bicep_file="$2" resource_type="$3" resource_type_dir="$4"
    local yaml_file entry_body
    yaml_file="$(yaml_file_for_resource_type "$resource_type_dir")"
    if [[ ! -f "$yaml_file" ]]; then
        echo "ERROR: [$pack_id] $resource_type: expected schema file not found: $yaml_file" >&2
        exit_code=1
        return
    fi

    mapfile -t schema_props < <(schema_property_names "$yaml_file")
    entry_body="$(rtc_recipe_pack_entry_body "$bicep_file" "$resource_type")"

    local expression property_names property_name compared_value
    while IFS= read -r expression; do
        [[ -z "$expression" ]] && continue
        checked_count=$((checked_count + 1))

        mapfile -t property_names < <(
            grep -oE 'context\.resource\.properties\.[A-Za-z0-9_]+' <<<"$expression" |
                sed -E 's/^context\.resource\.properties\.//' | sort -u
        )

        for property_name in "${property_names[@]}"; do
            [[ -z "$property_name" ]] && continue

            if ! printf '%s\n' "${schema_props[@]}" | grep -qx "$property_name"; then
                echo "ERROR: [$pack_id] $resource_type: references undeclared property '$property_name' in: $expression" >&2
                exit_code=1
                continue
            fi

            mapfile -t enum_values < <(schema_property_enum_values "$yaml_file" "$property_name")
            [[ ${#enum_values[@]} -eq 0 ]] && continue

            # Direct interpolation needs no comparison. Do not require a
            # separate branch for every value: shared defaults are valid.
            while IFS= read -r compared_value; do
                if ! printf '%s\n' "${enum_values[@]}" | grep -Fxq "$compared_value"; then
                    echo "ERROR: [$pack_id] $resource_type: '$property_name' compares undeclared enum value '$compared_value' in: $expression" >&2
                    exit_code=1
                fi
            done < <(
                grep -oE "context\.resource\.properties\.${property_name}[[:space:]]*==[[:space:]]*\"[^\"]*\"" <<<"$expression" |
                    sed -E 's/^[^"]*"([^"]*)".*/\1/'
            )
        done
    done < <(grep -oE '\{\{[^}]*\}\}' <<<"$entry_body")
}

packs="$(rtc_list_recipe_packs)"
rtc_list_platform_groups >/dev/null
while IFS= read -r pack_id; do
    [[ -z "$pack_id" ]] && continue
    bicep_file="$(rtc_recipe_pack_template "$pack_id")"
    direct_types="$(rtc_list_direct_module_types "$pack_id")"

    while IFS= read -r resource_type_dir; do
        [[ -z "$resource_type_dir" ]] && continue
        check_entry "$pack_id" "$bicep_file" "Radius.${resource_type_dir}" "$resource_type_dir"
    done <<<"$direct_types"
done <<<"$packs"

if [[ "$exit_code" -eq 0 ]]; then
    echo "Validated $checked_count direct-module mapping expression(s) across all checked-in Recipe Packs"
else
    echo "Direct-module mapping validation failed; see errors above." >&2
fi

exit "$exit_code"
