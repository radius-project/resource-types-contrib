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
# next-version.sh
# -----------------------------------------------------------------------------
# Resolve the current and next version for a namespace or a recipe pack from git
# tags, and print the tag to create. Git tags are the single source of truth;
# there is no version file to maintain.
#
# Inputs (environment variables):
#   NAMESPACE         a namespace to release, e.g. Radius.Data
#   RECIPE_PACK       a recipe pack to release, e.g. kubernetes
#                     (exactly one of NAMESPACE or RECIPE_PACK is required)
#   BUMP              patch|minor|major (default: minor)
#   PRERELEASE_LABEL  optional, e.g. rc.1 or beta.1; when set, appended as
#                     `-<label>` and the release is treated as a prerelease
#   REPO_ROOT         repository root (default: git toplevel, else CWD)
#   GITHUB_OUTPUT     optional; when set, outputs are written there too
#
# Outputs (stdout summary + $GITHUB_OUTPUT):
#   current           highest existing stable version (or "none")
#   next              resolved next version (e.g. 0.2.0 or 0.2.0-rc.1)
#   tag               full tag to create (e.g. Radius.Data/v0.2.0 or
#                     recipe-pack/kubernetes/v0.2.0)
#   is_prerelease     "true" | "false"
#
# Usage:
#   NAMESPACE=Radius.Data BUMP=minor ./.github/scripts/release/next-version.sh
#   RECIPE_PACK=kubernetes BUMP=minor ./.github/scripts/release/next-version.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/release/lib.sh
source "$SCRIPT_DIR/lib.sh"

NAMESPACE="${NAMESPACE:-}"
RECIPE_PACK="${RECIPE_PACK:-}"
BUMP="${BUMP:-minor}"
PRERELEASE_LABEL="${PRERELEASE_LABEL:-}"

if [[ -n "$NAMESPACE" && -n "$RECIPE_PACK" ]]; then
    echo "Error: set either NAMESPACE or RECIPE_PACK, not both" >&2
    exit 1
fi

# Resolve the released unit into its tag prefix; tags are `<prefix>/v<version>`.
if [[ -n "$RECIPE_PACK" ]]; then
    if ! rtc_is_recipe_pack "$RECIPE_PACK"; then
        echo "Error: '$RECIPE_PACK' is not a releasable recipe pack. Known recipe packs:" >&2
        rtc_list_recipe_packs | sed 's/^/  - /' >&2
        exit 1
    fi
    UNIT_LABEL="Recipe pack:"
    UNIT="$RECIPE_PACK"
    PREFIX="$(rtc_recipe_pack_tag_prefix "$RECIPE_PACK")"
elif [[ -n "$NAMESPACE" ]]; then
    if ! rtc_is_namespace "$NAMESPACE"; then
        echo "Error: '$NAMESPACE' is not a releasable namespace. Known namespaces:" >&2
        rtc_list_namespaces | sed 's/^/  - /' >&2
        exit 1
    fi
    UNIT_LABEL="Namespace:"
    UNIT="$NAMESPACE"
    PREFIX="$NAMESPACE"
else
    echo "Error: NAMESPACE or RECIPE_PACK is required (e.g. NAMESPACE=Radius.Data or RECIPE_PACK=kubernetes)" >&2
    exit 1
fi

CURRENT="$(rtc_latest_version "$PREFIX")"
BASE="${CURRENT:-0.0.0}"
NEXT="$(rtc_semver_bump "$BASE" "$BUMP")"

IS_PRERELEASE="false"
if [[ -n "$PRERELEASE_LABEL" ]]; then
    # Normalize: allow the caller to pass either "rc.1" or "-rc.1".
    PRERELEASE_LABEL="${PRERELEASE_LABEL#-}"
    if ! rtc_is_valid_prerelease "$PRERELEASE_LABEL"; then
        echo "Error: invalid SemVer prerelease label '$PRERELEASE_LABEL' (use dot-separated alphanumeric/hyphen identifiers; numeric identifiers cannot have leading zeroes)" >&2
        exit 1
    fi
    NEXT="${NEXT}-${PRERELEASE_LABEL}"
    IS_PRERELEASE="true"
fi

TAG="${PREFIX}/v${NEXT}"

if git -C "$RTC_REPO_ROOT" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
    echo "Error: tag '${TAG}' already exists" >&2
    exit 1
fi

rtc_emit "current" "${CURRENT:-none}"
rtc_emit "next" "$NEXT"
rtc_emit "tag" "$TAG"
rtc_emit "is_prerelease" "$IS_PRERELEASE"

{
    printf '%-14s %s\n' "$UNIT_LABEL" "$UNIT"
    printf '%-14s %s\n' "Current:" "${CURRENT:-none}"
    printf '%-14s %s\n' "Bump:" "$BUMP"
    printf '%-14s %s\n' "Next:" "$NEXT"
    printf '%-14s %s\n' "Tag:" "$TAG"
    printf '%-14s %s\n' "Prerelease:" "$IS_PRERELEASE"
} >&2
