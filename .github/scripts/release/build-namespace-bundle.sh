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
# build-namespace-bundle.sh
# -----------------------------------------------------------------------------
# Package a namespace's resource-type manifests into a release bundle plus a
# checksums file. The bundle contains each resource-type manifest YAML and its
# adjacent README.md, laid out under the repo-relative path (e.g.
# `Data/redisCaches/redisCaches.yaml`) so it extracts back into the same tree.
# Recipes and tests are intentionally excluded; recipes ship separately.
#
# Inputs (environment variables):
#   NAMESPACE   required, e.g. Radius.Data
#   VERSION     required, e.g. 0.2.0 (no leading `v`)
#   OUT_DIR     output directory (default: dist)
#   REPO_ROOT   repository root (default: git toplevel, else CWD)
#   GITHUB_OUTPUT optional; when set, outputs are written there too
#
# Outputs (stdout summary + $GITHUB_OUTPUT):
#   asset       path to the .tar.gz bundle
#   checksums   path to the checksums.txt
#   count       number of manifest files bundled
#
# Usage:
#   NAMESPACE=Radius.Data VERSION=0.1.0 ./.github/scripts/release/build-namespace-bundle.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/release/lib.sh
source "$SCRIPT_DIR/lib.sh"

NAMESPACE="${NAMESPACE:-}"
VERSION="${VERSION:-}"
OUT_DIR="${OUT_DIR:-dist}"

if [[ -z "$NAMESPACE" || -z "$VERSION" ]]; then
    echo "Error: NAMESPACE and VERSION are required" >&2
    exit 1
fi

if ! rtc_is_namespace "$NAMESPACE"; then
    echo "Error: '$NAMESPACE' is not a releasable namespace" >&2
    exit 1
fi

FOLDER="$(rtc_folder_for_namespace "$NAMESPACE")"
FOLDER_ABS="$RTC_REPO_ROOT/$FOLDER"
if [[ ! -d "$FOLDER_ABS" ]]; then
    echo "Error: namespace directory '$FOLDER' not found" >&2
    exit 1
fi

STAGING_COUNT=0
rtc_bundle_begin

# Collect resource-type manifests (<category>/<type>/<file>.yaml) and each
# type's adjacent README.md.
while IFS= read -r manifest; do
    rtc_is_resource_type_yaml "$manifest" || continue
    rtc_bundle_add_file "$manifest"
    STAGING_COUNT=$((STAGING_COUNT + 1))
    type_dir="$(dirname "$manifest")"
    if [[ -f "$type_dir/README.md" ]]; then
        rtc_bundle_add_file "$type_dir/README.md"
    fi
done < <(find "$FOLDER_ABS" -mindepth 2 -maxdepth 2 -type f \
    \( -name '*.yaml' -o -name '*.yml' \) | sort)

# Include a namespace-level README.md when present.
if [[ -f "$FOLDER_ABS/README.md" ]]; then
    rtc_bundle_add_file "$FOLDER_ABS/README.md"
fi

if [[ "$STAGING_COUNT" -eq 0 ]]; then
    echo "Error: no resource-type manifests found under '$FOLDER'" >&2
    exit 1
fi

rtc_bundle_create "$OUT_DIR" "${NAMESPACE}-manifests-v${VERSION}.tar.gz"

rtc_emit "asset" "$RTC_BUNDLE_ASSET"
rtc_emit "checksums" "$RTC_BUNDLE_CHECKSUMS"
rtc_emit "count" "$STAGING_COUNT"

{
    echo "Namespace:   $NAMESPACE"
    echo "Version:     $VERSION"
    echo "Manifests:   $STAGING_COUNT"
    echo "Asset:       $RTC_BUNDLE_ASSET"
    echo "Checksums:   $RTC_BUNDLE_CHECKSUMS"
    echo "SHA256:      $(cut -d' ' -f1 "$RTC_BUNDLE_CHECKSUMS")"
} >&2
