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
# build-recipe-pack-bundle.sh
# -----------------------------------------------------------------------------
# Package a recipe pack into a release bundle plus a checksums file. The bundle
# contains the pack's Bicep templates and its README.md, laid out under the
# repo-relative path (e.g. `recipe-packs/kubernetes/default-recipepack.bicep`) so
# it extracts back into the same tree. This is the recipe pack counterpart of
# build-namespace-bundle.sh and shares its bundling helpers.
#
# Inputs (environment variables):
#   RECIPE_PACK   required, e.g. kubernetes
#   VERSION       required, e.g. 0.2.0 (no leading `v`)
#   OUT_DIR       output directory (default: dist)
#   REPO_ROOT     repository root (default: git toplevel, else CWD)
#   GITHUB_OUTPUT optional; when set, outputs are written there too
#
# Outputs (stdout summary + $GITHUB_OUTPUT):
#   asset       path to the .tar.gz bundle
#   checksums   path to the checksums.txt
#   count       number of Bicep templates bundled
#
# Usage:
#   RECIPE_PACK=kubernetes VERSION=0.1.0 ./.github/scripts/release/build-recipe-pack-bundle.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/release/lib.sh
source "$SCRIPT_DIR/lib.sh"

RECIPE_PACK="${RECIPE_PACK:-}"
VERSION="${VERSION:-}"
OUT_DIR="${OUT_DIR:-dist}"

if [[ -z "$RECIPE_PACK" || -z "$VERSION" ]]; then
    echo "Error: RECIPE_PACK and VERSION are required" >&2
    exit 1
fi

if ! rtc_is_recipe_pack "$RECIPE_PACK"; then
    echo "Error: '$RECIPE_PACK' is not a releasable recipe pack" >&2
    exit 1
fi

PACK_DIR="$(rtc_recipe_pack_dir "$RECIPE_PACK")"
PACK_DIR_ABS="$RTC_REPO_ROOT/$PACK_DIR"

STAGING_COUNT=0
rtc_bundle_begin

# Collect the pack's Bicep templates (recipe-packs/<pack>/<file>.bicep).
while IFS= read -r template; do
    rtc_bundle_add_file "$template"
    STAGING_COUNT=$((STAGING_COUNT + 1))
done < <(find "$PACK_DIR_ABS" -mindepth 1 -maxdepth 1 -type f -name '*.bicep' | sort)

# Include the pack README.md when present.
if [[ -f "$PACK_DIR_ABS/README.md" ]]; then
    rtc_bundle_add_file "$PACK_DIR_ABS/README.md"
fi

if [[ "$STAGING_COUNT" -eq 0 ]]; then
    echo "Error: no Bicep templates found under '$PACK_DIR'" >&2
    exit 1
fi

rtc_bundle_create "$OUT_DIR" "${RTC_RECIPE_PACK_TAG_PREFIX}-${RECIPE_PACK}-v${VERSION}.tar.gz"

rtc_emit "asset" "$RTC_BUNDLE_ASSET"
rtc_emit "checksums" "$RTC_BUNDLE_CHECKSUMS"
rtc_emit "count" "$STAGING_COUNT"

{
    echo "Recipe pack: $RECIPE_PACK"
    echo "Version:     $VERSION"
    echo "Templates:   $STAGING_COUNT"
    echo "Asset:       $RTC_BUNDLE_ASSET"
    echo "Checksums:   $RTC_BUNDLE_CHECKSUMS"
    echo "SHA256:      $(cut -d' ' -f1 "$RTC_BUNDLE_CHECKSUMS")"
} >&2
