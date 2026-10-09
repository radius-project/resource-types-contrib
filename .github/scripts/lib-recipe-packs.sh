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
# lib-recipe-packs.sh
# -----------------------------------------------------------------------------
# Single source of truth for everything CI needs to know about the checked-in
# Recipe Packs under recipe-packs/. Three questions, three functions:
#
#   rtc_recipe_pack_platform_group <pack-id>
#       "What platform does this pack target?" e.g. azure-aks -> azure.
#       This is the ONE place to touch when adding a pack for a platform that
#       already has a CI job (kubernetes, azure). Adding support for a new
#       platform group entirely also means adding a CI job that calls these
#       scripts with that group name.
#
#   rtc_recipe_packs_for_platform_group <platform-group>
#       "Which packs target this platform?" Built on
#       rtc_list_recipe_packs() (lib-namespaces.sh), so a new pack directory
#       under recipe-packs/ is picked up automatically -- no code change
#       needed beyond the platform-group mapping above.
#
#   rtc_list_direct_module_types <pack-id>
#       "Which Resource Types in this pack have no backing recipe elsewhere in
#       this repo?" i.e. entries whose `source` is a third-party module (an
#       AVM module, etc.) written directly into the pack, as opposed to
#       entries whose `source` is one of this repo's own published recipe
#       images (ghcr.io/radius-project/*-recipes/*, built from this repo's
#       own recipes/<platform>/ folders and already tested when that folder
#       is tested). These are the coverage gaps issue #312 is about: a
#       Resource Type with a `test/app.bicep` whose pack entry is a direct
#       third-party module reference is never deployed anywhere else in CI,
#       so this is the only place a bad mapping would be caught.
#
# Consumers (every one of them reads from this file instead of hand-listing
# packs or gaps, so adding a pack or a gap needs no new test code):
#   - deploy-all-checked-in-recipe-packs.sh  (Layer 1: does the pack deploy?)
#   - validate-direct-module-mappings.sh     (Layer 2: are the gap mappings
#     correct, checked statically, no cloud cost?)
#   - test-direct-module-recipe.sh / the nightly workflow (Layer 3: does the
#     gap actually work against real infrastructure?)
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib-recipe-packs.sh"
# =============================================================================

# Guard against double-sourcing.
if [[ -n "${RTC_LIB_RECIPE_PACKS_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
RTC_LIB_RECIPE_PACKS_SOURCED=1

RTC_LIB_RECIPE_PACKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-namespaces.sh
source "$RTC_LIB_RECIPE_PACKS_DIR/lib-namespaces.sh"

# Map a recipe pack id (a directory name under recipe-packs/) to the platform
# group it targets. A platform group is what a CI job actually brings up
# (a local k3d cluster for "kubernetes", a real subscription for "azure") --
# more than one pack can target the same platform group (azure-aks and
# azure-aci both target "azure").
#
# Add one line here for a new pack on an EXISTING platform group. Supporting a
# genuinely new platform group also requires a CI job that calls the scripts
# in this family with that group name.
rtc_recipe_pack_platform_group() {
    case "$1" in
        kubernetes)
            echo "kubernetes"
            ;;
        azure-aks | azure-aci)
            echo "azure"
            ;;
        *)
            echo "Error: no platform group mapping for recipe pack '$1'. Add one to rtc_recipe_pack_platform_group() in lib-recipe-packs.sh." >&2
            return 1
            ;;
    esac
}

# Print every distinct platform group across all checked-in packs, one per
# line, sorted. Used to drive CI matrices without hand-listing groups.
rtc_list_platform_groups() {
    local pack packs group groups=""
    packs="$(rtc_list_recipe_packs)" || return 1
    while IFS= read -r pack; do
        [[ -z "$pack" ]] && continue
        group="$(rtc_recipe_pack_platform_group "$pack")" || return 1
        groups+="$group"$'\n'
    done <<<"$packs"
    printf '%s' "$groups" | sort -u
}

# Print the recipe pack ids that target the given platform group, one per
# line, sorted.
rtc_recipe_packs_for_platform_group() {
    local target="$1" pack group packs groups
    groups="$(rtc_list_platform_groups)" || return 1
    if ! grep -Fxq "$target" <<<"$groups"; then
        echo "Error: no checked-in packs for platform group '$target'." >&2
        return 1
    fi
    packs="$(rtc_list_recipe_packs)" || return 1
    while IFS= read -r pack; do
        [[ -z "$pack" ]] && continue
        if ! group="$(rtc_recipe_pack_platform_group "$pack")"; then
            return 1
        fi
        [[ "$group" == "$target" ]] && echo "$pack"
    done <<<"$packs"
    return 0
}

# Print the absolute path(s) of the Bicep template file(s) for a recipe pack,
# one per line, sorted. Normally exactly one file per pack.
rtc_recipe_pack_bicep_files() {
    local pack_id="$1" dir
    dir="$RTC_REPO_ROOT/$(rtc_recipe_pack_dir "$pack_id")"
    find "$dir" -maxdepth 1 -type f -name '*.bicep' 2>/dev/null | sort
}

# Each pack must have one template; do not silently choose the first file.
rtc_recipe_pack_template() {
    local files
    files="$(rtc_recipe_pack_bicep_files "$1")" || return 1
    if [[ -z "$files" || "$files" == *$'\n'* ]]; then
        echo "Error: recipe pack '$1' must have exactly one .bicep template." >&2
        return 1
    fi
    printf '%s\n' "$files"
}

# Print the `name:` value of a recipe pack Bicep file's
# `Radius.Core/recipePacks` resource -- the value `rad env update
# --recipe-packs <name>` must be given. This is NOT always the same as the
# pack id (the recipe-packs/<pack-id>/ directory name): recipe-packs/kubernetes
# declares `name: 'default'`.
rtc_recipe_pack_name() {
    local bicep_file="$1"
    awk '
        /resource[[:space:]]+[A-Za-z0-9_]+[[:space:]]+'"'"'Radius\.Core\/recipePacks@/ { capture=1; next }
        capture && /^\s*name:[[:space:]]*'"'"'[^'"'"']*'"'"'/ {
            match($0, /name:[[:space:]]*'"'"'[^'"'"']*'"'"'/)
            s = substr($0, RSTART, RLENGTH)
            sub(/^name:[[:space:]]*'"'"'/, "", s)
            sub(/'"'"'$/, "", s)
            print s
            exit
        }
    ' "$bicep_file" 2>/dev/null
}

# Print the names of a Bicep file's required parameters -- `param <name>
# <type>` declarations with no `= <default>` -- one per line, in file order.
rtc_recipe_pack_required_params() {
    local bicep_file="$1"
    awk '/^param[[:space:]]+[A-Za-z0-9_]+[[:space:]]/ && !/=/ { print $2 }' "$bicep_file"
}

# Prefix shared by every recipe image this repo builds and publishes itself
# (see .github/workflows/publish-bicep-recipes.yaml). A pack entry whose
# `source` starts with this prefix is "repo-owned": it is built from one of
# this repo's own recipes/<platform>/ folders and is already exercised by the
# existing per-folder recipe test flow, regardless of which pack(s)
# reference it.
RTC_REPO_RECIPE_SOURCE_PREFIX='ghcr.io/radius-project/'

# Print "<Resource Type>\t<source>" pairs (e.g.
# "Radius.Data/redisCaches\tmcr.microsoft.com/bicep/avm/res/cache/redis-enterprise:0.5.1")
# for every entry in a pack's `recipes` map, one per line, in file order.
#
# Relies on every entry following the fixed two-line shape used throughout
# recipe-packs/**:
#   'Radius.<Category>/<type>': {
#     kind: 'bicep'
#     source: '<source>'
#     ...
# i.e. the first `source:` line after a type key is always that entry's own
# source, never a nested one (nested `source:` values, such as AVM
# `configurations` entries using `source: 'user-override'`, only appear
# further down, after this first match).
rtc_recipe_pack_entries() {
    local bicep_file="$1"
    awk '
        /^\s*'"'"'Radius\.[A-Za-z0-9]+\/[A-Za-z0-9]+'"'"':[[:space:]]*\{/ {
            match($0, /Radius\.[A-Za-z0-9]+\/[A-Za-z0-9]+/)
            current_type = substr($0, RSTART, RLENGTH)
            next
        }
        current_type != "" && /^\s*source:[[:space:]]*'"'"'[^'"'"']*'"'"'/ {
            match($0, /source:[[:space:]]*'"'"'[^'"'"']*'"'"'/)
            source_literal = substr($0, RSTART, RLENGTH)
            sub(/^source:[[:space:]]*'"'"'/, "", source_literal)
            sub(/'"'"'$/, "", source_literal)
            print current_type "\t" source_literal
            current_type = ""
        }
    ' "$bicep_file" 2>/dev/null
}

# Convert a Resource Type entry ("Radius.Data/redisCaches") to its repo-relative
# directory ("Data/redisCaches").
rtc_resource_type_dir_for_entry() {
    echo "${1#Radius.}"
}

# True (exit 0) if the given Resource Type has a test application AND the
# given source is not one of this repo's own published recipe images --
# i.e. it is a "direct module" gap: the only way this entry gets exercised at
# all is by deploying the pack and checking this specific mapping, because no
# recipes/<platform>/ folder test already covers it. False for Resource Types
# this repo builds and tests its own recipe for (repo-owned source), and for
# Resource Types with no test/app.bicep at all (nothing to deploy either way).
rtc_is_direct_module_type() {
    local resource_type_dir="$1" source="$2" type_root
    type_root="$RTC_REPO_ROOT/$resource_type_dir"
    [[ -f "$type_root/test/app.bicep" ]] || return 1
    [[ "$source" == "$RTC_REPO_RECIPE_SOURCE_PREFIX"* ]] && return 1
    return 0
}

# CI test value for a recipe pack's required (no-default) Bicep parameter.
# Add one case arm whenever a pack gains a new required parameter so
# deploy-all-checked-in-recipe-packs.sh can deploy it without prompting.
# Shared across callers (the PR deploy step and the nightly workflow) so
# there is one place to update when a parameter's test value needs to change.
rtc_recipe_pack_param_value() {
    case "$1" in
        routesGatewayName)
            echo "validation-gateway"
            ;;
        containerImagesRegistry)
            echo "localhost:5000"
            ;;
        *)
            echo "Error: no CI test value for required recipe pack parameter '$1'. Add one to rtc_recipe_pack_param_value() in lib-recipe-packs.sh." >&2
            return 1
            ;;
    esac
}

# Print the full Bicep body (balanced braces, exclusive of the enclosing
# `{ ... }`) of one Resource Type entry in a pack's `recipes` map. Used to
# scan an entry's parameters/outputs for `{{context.resource.properties.*}}`
# expressions without matching text belonging to a different entry.
rtc_recipe_pack_entry_body() {
    local bicep_file="$1" resource_type="$2"
    awk -v want="'${resource_type}':" '
        BEGIN { depth = 0; capturing = 0 }
        {
            line = $0
            if (!capturing) {
                if (index(line, want) > 0 && line ~ /\{[[:space:]]*$/) {
                    capturing = 1
                    depth = 1
                }
                next
            }
            opens = gsub(/\{/, "{", line)
            closes = gsub(/\}/, "}", line)
            depth += opens - closes
            if (depth <= 0) {
                capturing = 0
                next
            }
            print line
        }
    ' "$bicep_file" 2>/dev/null
}

# Print the Resource Type directories (e.g. "Data/mySqlDatabases") in a pack
# that are direct-module gaps, one per line, in file order.
rtc_list_direct_module_types() {
    local pack_id="$1" bicep_file entries resource_type entry_source resource_type_dir
    bicep_file="$(rtc_recipe_pack_template "$pack_id")" || return 1
    entries="$(rtc_recipe_pack_entries "$bicep_file")" || return 1
    while IFS=$'\t' read -r resource_type entry_source; do
        [[ -z "$resource_type" ]] && continue
        resource_type_dir="$(rtc_resource_type_dir_for_entry "$resource_type")"
        if rtc_is_direct_module_type "$resource_type_dir" "$entry_source"; then
            echo "$resource_type_dir"
        fi
    done <<<"$entries"
}
