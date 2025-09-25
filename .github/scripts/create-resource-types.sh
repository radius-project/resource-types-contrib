#!/bin/bash

# =============================================================================
# validate-resource-types.sh
# -----------------------------------------------------------------------------
# Validate Radius resource type definitions by running `rad resource-type create`
# against each YAML file located at the root of the provided folder. The script
# accepts exactly one argument: the path to a folder containing resource type
# YAML files. Each file is processed independently so that validation continues
# across failures. The script exits with a non-zero status if any validation
# fails.
# =============================================================================

set -euo pipefail

validate_dependencies() {
    if ! command -v rad >/dev/null 2>&1; then
        echo "Error: 'rad' command not found in PATH" >&2
        exit 1
    fi
}

validate_yaml_file() {
    local yaml_file="$1"

    local output
    if output=$(rad resource-type create -f "$yaml_file" 2>&1); then
        echo "PASS $yaml_file"
    else
        echo "$output" >&2
        echo "FAIL $yaml_file"
        VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
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

    VALIDATION_FAILURES=0

    local -a yaml_files=()
    mapfile -d '' -t yaml_files < <(find "$target_folder" -maxdepth 1 -mindepth 1 -type f \
        \( -name '*.yaml' -o -name '*.yml' \) -print0)

    for yaml_file in "${yaml_files[@]}"; do
        validate_yaml_file "$yaml_file"
    done

    if [[ $VALIDATION_FAILURES -ne 0 ]]; then
        exit 1
    fi
}

main "$@"
