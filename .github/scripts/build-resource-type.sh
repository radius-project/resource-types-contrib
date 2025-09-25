#!/bin/bash

# =============================================================================
# build-resource-type.sh
# -----------------------------------------------------------------------------
# Validate Radius resource type definitions by running `rad resource-type create`
# against each YAML file located at the root of the provided folder, and publish
# the matching resource type extension using `rad bicep publish-extension`. The
# script accepts exactly one argument: the path to a folder containing resource
# type YAML files. The script exits immediately if any command fails.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

validate_dependencies() {
    if ! command -v rad >/dev/null 2>&1; then
        echo "Error: 'rad' command not found in PATH" >&2
        exit 1
    fi
}

create_resource_type() {
    local yaml_file="$1"

    local output
    if output=$(rad resource-type create -f "$yaml_file" 2>&1); then
        echo "PASS $yaml_file"
        return 0
    else
        echo "$output" >&2
        echo "FAIL $yaml_file"
        return 1
    fi
}

publish_extension() {
    local yaml_file="$1"

    local base_name extension_name target_path output
    base_name="$(basename "$yaml_file")"
    extension_name="${base_name%.*}"
    target_path="${REPO_ROOT}/${extension_name}.tgz"

    if output=$(rad bicep publish-extension -f "$yaml_file" --target "$target_path" 2>&1); then
        echo "EXT PASS $yaml_file"
    else
        echo "$output" >&2
        echo "EXT FAIL $yaml_file"
        return 1
    fi
}

main() {
    validate_dependencies

    if [[ $# -ne 1 ]]; then
        echo "Error: Expected exactly one folder argument" >&2
        exit 1
    fi

    local target_folder="$1"
    if [[ "$target_folder" != /* ]]; then
        target_folder="$(pwd)/$target_folder"
    fi

    if [[ ! -d "$target_folder" ]]; then
        echo "Error: folder '$target_folder' does not exist" >&2
        exit 1
    fi

    target_folder="$(cd "$target_folder" && pwd)"

    local -a yaml_files=()
    mapfile -d '' -t yaml_files < <(find "$target_folder" -maxdepth 1 -mindepth 1 -type f \
        \( -name '*.yaml' -o -name '*.yml' \) -print0)

    for yaml_file in "${yaml_files[@]}"; do
        create_resource_type "$yaml_file"
        publish_extension "$yaml_file"
    done
}

main "$@"
