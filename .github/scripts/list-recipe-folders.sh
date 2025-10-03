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
