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
# list-resource-type-folders.sh
# -----------------------------------------------------------------------------
# Find directories that contain Radius resource type definitions. A resource
# type directory contains a YAML file whose first two non-empty lines are
# "namespace:" followed by "types:". Directories beginning with "." and the
# "docs" directory are skipped. The script accepts an optional root directory
# argument and defaults to the current working directory.
# =============================================================================

set -euo pipefail

ROOT_DIR="$(pwd)"

resolve_root_dir() {
    if [[ "$#" -gt 1 ]]; then
        echo "Error: Too many arguments" >&2
        exit 1
    fi

    if [[ "$#" -eq 1 ]]; then
        ROOT_DIR="$1"
    fi

    if [[ ! -d "$ROOT_DIR" ]]; then
        echo "Error: Root directory '$ROOT_DIR' does not exist" >&2
        exit 1
    fi

    ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"
}

# Determines if a given yaml file is a resource type definition by checking
# if its first two non-empty, non-comment lines are "namespace:" and "types:"
is_resource_type_yaml() {
    local file="$1"
    local line1=""
    local line2=""
    local line

    # Skip blank lines, comments, and YAML document markers at the top of the file.
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*$ ]]; then
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*(-{3}|\.{3})[[:space:]]*$ ]]; then
            continue
        fi

        if [[ -z "$line1" ]]; then
            line1="$line"
            continue
        fi

        line2="$line"
        break
    done < "$file"

    if [[ -z "$line1" || -z "$line2" ]]; then
        return 1
    fi

    [[ "$line1" =~ ^[[:space:]]*namespace:[[:space:]]* ]] || return 1
    [[ "$line2" =~ ^[[:space:]]*types:[[:space:]]* ]] || return 1

    return 0
}

collect_resource_type_dirs() {
    declare -A seen_dirs=()
    local path

    # Traverse the repository, skipping hidden and docs directories, while checking
    # each YAML file encountered. Matching directories are recorded in an
    # associative array to avoid duplicate output when multiple files qualify.
    while IFS= read -r -d '' path; do
        if is_resource_type_yaml "$path"; then
            local dir
            dir="$(dirname "$path")"
            seen_dirs["$dir"]=1
        fi
    done < <(find "$ROOT_DIR" \
        \( -type d -name '.*' -o -type d -name 'docs' \) -prune -o \
        -type f -name '*.yaml' -print0)

    # Output sorted full paths so results are stable regardless of discovery order.
    printf '%s\n' "${!seen_dirs[@]}" | sort
}

main() {
    resolve_root_dir "$@"
    collect_resource_type_dirs
}

main "$@"
