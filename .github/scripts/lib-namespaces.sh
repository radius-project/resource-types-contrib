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
# lib-namespaces.sh
# -----------------------------------------------------------------------------
# Shared helpers for enumerating the two kinds of units this repository
# publishes -- resource-type namespaces and recipe packs -- and mapping them to
# their directories. Sourced by both the Radius sync payload script
# (compute-radius-sync-payload.sh) and the release tooling (release/lib.sh) so
# there is ONE definition of each unit.
#
# A namespace is `Radius.<Category>` and maps 1:1 to a top-level category
# directory (e.g. Radius.Data <-> Data/). A directory is only treated as a
# category when it actually contains a resource-type manifest -- a YAML file
# with a top-level `namespace: Radius.*` and a `types:` block -- so unrelated
# top-level folders are never mistaken for namespaces.
#
# A recipe pack is a directory under recipe-packs/ (e.g. recipe-packs/azure)
# that holds at least one Bicep template.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib-namespaces.sh"     # or "$SCRIPT_DIR/../lib-namespaces.sh"
# =============================================================================

# Guard against double-sourcing.
if [[ -n "${RTC_LIB_NAMESPACES_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
RTC_LIB_NAMESPACES_SOURCED=1

RTC_REPO_ROOT="${RTC_REPO_ROOT:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"

# Top-level directories that are never resource-type namespaces.
rtc_is_excluded_dir() {
    case "$1" in
        .github | docs | recipe-packs | recipepack | dist | .git | .devcontainer | .vscode | .idea)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# True if the file is a resource-type manifest (top-level `namespace: Radius.*`
# and a `types:` block).
rtc_is_resource_type_yaml() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -qE '^namespace:[[:space:]]*Radius\.' "$file" 2>/dev/null &&
        grep -qE '^types:' "$file" 2>/dev/null
}

# Print the top-level category directories that contain at least one resource
# type manifest (`<category>/<type>/<file>.yaml`), one per line, sorted. Cached
# because callers scan it once per changed file.
RTC_FOLDERS_CACHE=""
rtc_list_folders() {
    if [[ -z "$RTC_FOLDERS_CACHE" ]]; then
        RTC_FOLDERS_CACHE="$(_rtc_scan_folders)"
    fi
    printf '%s\n' "$RTC_FOLDERS_CACHE"
}

_rtc_scan_folders() {
    local dir base file
    # Enumerate only the immediate top-level directories and skip excluded ones
    # BEFORE descending, so find never traverses large trees such as .git/ or
    # .github/. Each remaining category directory is then scanned just two
    # levels deep for a resource-type manifest (<category>/<type>/<file>.yaml).
    while IFS= read -r dir; do
        base="${dir##*/}"
        rtc_is_excluded_dir "$base" && continue
        while IFS= read -r file; do
            if rtc_is_resource_type_yaml "$file"; then
                echo "$base"
                break
            fi
        done < <(find "$dir" -mindepth 2 -maxdepth 2 -type f \
            \( -name '*.yaml' -o -name '*.yml' \))
    done < <(find "$RTC_REPO_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
}

# Print the releasable namespaces (`Radius.<Category>`), one per line.
rtc_list_namespaces() {
    local folder
    while IFS= read -r folder; do
        [[ -z "$folder" ]] && continue
        echo "Radius.$folder"
    done < <(rtc_list_folders)
}

# Map between a namespace and its category directory.
rtc_folder_for_namespace() { echo "${1#Radius.}"; }
rtc_namespace_for_folder() { echo "Radius.$1"; }

# True if the argument is a known category directory (e.g. "Data").
rtc_is_category() {
    local category="$1" candidate
    while IFS= read -r candidate; do
        [[ "$candidate" == "$category" ]] && return 0
    done < <(rtc_list_folders)
    return 1
}

# True if the argument is a known releasable namespace (e.g. "Radius.Data").
rtc_is_namespace() {
    local ns="$1" candidate
    while IFS= read -r candidate; do
        [[ "$candidate" == "$ns" ]] && return 0
    done < <(rtc_list_namespaces)
    return 1
}

# Recipe packs live one directory below this root. Their tags carry a
# `recipe-pack/` prefix so they never collide with the namespace tag series and
# so the Radius sync tooling can recognize the scope.
RTC_RECIPE_PACK_ROOT="${RTC_RECIPE_PACK_ROOT:-recipe-packs}"
RTC_RECIPE_PACK_TAG_PREFIX="recipe-pack"

# Print the releasable recipe packs (directory names under recipe-packs/), one
# per line, sorted. A directory is only treated as a pack when it holds a Bicep
# template, so unrelated folders are never mistaken for a pack.
rtc_list_recipe_packs() {
    local dir
    [[ -d "$RTC_REPO_ROOT/$RTC_RECIPE_PACK_ROOT" ]] || return 0
    while IFS= read -r dir; do
        if compgen -G "$dir/*.bicep" >/dev/null; then
            echo "${dir##*/}"
        fi
    done < <(find "$RTC_REPO_ROOT/$RTC_RECIPE_PACK_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
}

# True if the argument is a known recipe pack (e.g. "kubernetes").
rtc_is_recipe_pack() {
    local pack="$1" candidate
    while IFS= read -r candidate; do
        [[ "$candidate" == "$pack" ]] && return 0
    done < <(rtc_list_recipe_packs)
    return 1
}

# Map a recipe pack to its tag prefix and directory
# (e.g. kubernetes -> recipe-pack/kubernetes, recipe-packs/kubernetes).
rtc_recipe_pack_tag_prefix() { echo "${RTC_RECIPE_PACK_TAG_PREFIX}/$1"; }
rtc_recipe_pack_dir() { echo "${RTC_RECIPE_PACK_ROOT}/$1"; }
