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
# Publish a single Radius Bicep recipe by running `rad bicep publish` against a
# specified recipe file. The script accepts exactly one argument: the path to a
# Bicep recipe located under a resource type directory following the pattern
# `<resource>/recipes/<platform>/<language>/<recipe>.bicep`.
# =============================================================================

set -euo pipefail

REGISTRY_BASE="localhost:5000/radius-recipes"
REGISTRY_TAG="latest"

# Normalize an individual path segment to lowercase and OCI-safe characters.
sanitize_segment() {
    local segment="$1"

    segment="$(printf '%s' "$segment" | tr '[:upper:]' '[:lower:]')"
    segment="$(printf '%s' "$segment" | sed -E 's/[^a-z0-9._-]+/-/g')"
    segment="$(printf '%s' "$segment" | sed -E 's/-{2,}/-/g')"
    segment="$(printf '%s' "$segment" | sed -E 's/^-+|-+$//g')"

    if [[ -z "$segment" ]]; then
        echo "Error: path segment '$1' is invalid after sanitization" >&2
        exit 1
    fi

    printf '%s' "$segment"
}

# Sanitize an entire path by processing each segment and rejoining them.
sanitize_path() {
    local path="$1"

    if [[ -z "$path" ]]; then
        echo ""
        return 0
    fi

    local IFS='/'
    read -ra parts <<< "$path"

    local sanitized_parts=()
    local part
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        if [[ "$part" == "." ]]; then
            continue
        fi
        if [[ "$part" == ".." ]]; then
            echo "Error: path segment '..' is not allowed in '$path'" >&2
            exit 1
        fi
        sanitized_parts+=("$(sanitize_segment "$part")")
    done

    local sanitized=""
    for part in "${sanitized_parts[@]}"; do
        sanitized+="/$part"
    done

    echo "${sanitized#/}"
}

# Check if the registry is accessible
check_registry_connectivity() {
    local registry_host="${REGISTRY_BASE%%/*}"
    local max_attempts=3
    local attempt=1
    
    echo "Checking connectivity to registry: $registry_host"
    
    while [ $attempt -le $max_attempts ]; do
        if curl -sSf "http://$registry_host/v2/" > /dev/null 2>&1; then
            echo "Registry is accessible"
            return 0
        fi
        echo "Attempt $attempt/$max_attempts: Registry not ready, waiting 2 seconds..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "❌ Registry $registry_host is not accessible after $max_attempts attempts" >&2
    return 1
}

# Publish the provided recipe file to the fixed local registry target.
publish_recipe() {
    local recipe_file="$1"
    local resource_relpath="$2"
    local recipes_dir="$3"
    local recipe_name="$4"

    if ! check_registry_connectivity; then
        exit 1
    fi

    local target_path="$REGISTRY_BASE"
    local sanitized_resource
    sanitized_resource="$(sanitize_path "$resource_relpath")"
    if [[ -n "$sanitized_resource" ]]; then
        target_path+="/$sanitized_resource"
    fi

    local sanitized_recipes_dir
    sanitized_recipes_dir="$(sanitize_path "$recipes_dir")"
    if [[ -n "$sanitized_recipes_dir" ]]; then
        target_path+="/$sanitized_recipes_dir"
    fi

    local sanitized_name
    sanitized_name="$(sanitize_segment "$recipe_name")"
    target_path+="/$sanitized_name:$REGISTRY_TAG"

    if rad bicep publish --file "$recipe_file" --target "br:$target_path" --plain-http; then
        return 0
    else
        echo "❌ Failed publishing recipe: $recipe_file" >&2
        exit 1
    fi
}

main() {

    if [[ $# -ne 1 ]]; then
        echo "Error: Expected exactly one Bicep recipe file argument" >&2
        exit 1
    fi

    local recipe_file="$1"
    if [[ "$recipe_file" != /* ]]; then
        recipe_file="$(pwd)/$recipe_file"
    fi
    recipe_file="$(cd "$(dirname "$recipe_file")" && pwd)/$(basename "$recipe_file")"

    if [[ ! -f "$recipe_file" ]]; then
        echo "Error: recipe file '$recipe_file' does not exist" >&2
        exit 1
    fi

    local recipe_rel
    recipe_rel="$(realpath --relative-to="$(pwd)" "$recipe_file" 2>/dev/null || echo "$recipe_file")"

    if [[ "$recipe_rel" != */recipes/*/*.bicep ]]; then
        echo "Error: recipe path must match */recipes/*/*.bicep" >&2
        exit 1
    fi

    local resource_relpath="${recipe_rel%%/recipes/*}"
    if [[ -z "$resource_relpath" ]]; then
        echo "Error: unable to determine resource type path from '$recipe_rel'" >&2
        exit 1
    fi

    local recipes_subpath="${recipe_rel#${resource_relpath}/recipes/}"
    local recipes_dir="${recipes_subpath%/*}"
    local recipe_filename="${recipes_subpath##*/}"
    local recipe_name="${recipe_filename%.bicep}"

    publish_recipe "$recipe_file" "$resource_relpath" "$recipes_dir" "$recipe_name"
}

main "$@"
