#!/bin/bash

# =============================================================================
# list-recipe-folders.sh
# -----------------------------------------------------------------------------
# Find all directories that contain recipes (Bicep or Terraform).
# Lists both Bicep recipe directories (containing .bicep files) and Terraform
# recipe directories (named 'terraform' with main.tf).
#
# Usage:
#   ./list-recipe-folders.sh [ROOT_DIR]
# If ROOT_DIR is omitted, defaults to the current working directory.
# =============================================================================

set -euo pipefail

ROOT_DIR="${1:-$(pwd)}"

if [[ ! -d "$ROOT_DIR" ]]; then
    echo "Error: Root directory '$ROOT_DIR' does not exist" >&2
    exit 1
fi

ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

# Find all Bicep recipe directories (directories containing .bicep files under recipes/)
find "$ROOT_DIR" -type f -path "*/recipes/*/*.bicep" -print0 2>/dev/null | \
    xargs -0 -n1 dirname 2>/dev/null | \
    sort -u

# Find all Terraform recipe directories (directories named 'terraform' under recipes/)
find "$ROOT_DIR" -type d -path "*/recipes/*/terraform" -print0 2>/dev/null | \
    xargs -0 -n1 printf '%s\n' 2>/dev/null | \
    sort -u
