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
# Resolve the current and next version for a namespace from git tags, and print
# the tag to create. Git tags are the single source of truth; there is no
# version file to maintain.
#
# Inputs (environment variables):
#   NAMESPACE         required, e.g. Radius.Data
#   BUMP              patch|minor|major (default: minor)
#   PRERELEASE_LABEL  optional, e.g. rc.1 or beta.1; when set, appended as
#                     `-<label>` and the release is treated as a prerelease
#   REPO_ROOT         repository root (default: git toplevel, else CWD)
#   GITHUB_OUTPUT     optional; when set, outputs are written there too
#
# Outputs (stdout summary + $GITHUB_OUTPUT):
#   current           highest existing stable version (or "none")
#   next              resolved next version (e.g. 0.2.0 or 0.2.0-rc.1)
#   tag               full tag to create (e.g. Radius.Data/v0.2.0)
#   is_prerelease     "true" | "false"
#
# Usage:
#   NAMESPACE=Radius.Data BUMP=minor ./.github/scripts/release/next-version.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/release/lib.sh
source "$SCRIPT_DIR/lib.sh"

NAMESPACE="${NAMESPACE:-}"
BUMP="${BUMP:-minor}"
PRERELEASE_LABEL="${PRERELEASE_LABEL:-}"

if [[ -z "$NAMESPACE" ]]; then
    echo "Error: NAMESPACE is required (e.g. NAMESPACE=Radius.Data)" >&2
    exit 1
fi

if ! rtc_is_namespace "$NAMESPACE"; then
    echo "Error: '$NAMESPACE' is not a releasable namespace. Known namespaces:" >&2
    rtc_list_namespaces | sed 's/^/  - /' >&2
    exit 1
fi

CURRENT="$(rtc_latest_version "$NAMESPACE")"
BASE="${CURRENT:-0.0.0}"
NEXT="$(rtc_semver_bump "$BASE" "$BUMP")"

IS_PRERELEASE="false"
if [[ -n "$PRERELEASE_LABEL" ]]; then
    # Normalize: allow the caller to pass either "rc.1" or "-rc.1".
    PRERELEASE_LABEL="${PRERELEASE_LABEL#-}"
    # Restrict to the SemVer prerelease charset so the resulting tag is valid.
    if [[ ! "$PRERELEASE_LABEL" =~ ^[0-9A-Za-z]([0-9A-Za-z.-]*[0-9A-Za-z])?$ ]]; then
        echo "Error: invalid prerelease label '$PRERELEASE_LABEL' (allowed: alphanumerics, '.', '-'; must start and end alphanumeric)" >&2
        exit 1
    fi
    NEXT="${NEXT}-${PRERELEASE_LABEL}"
    IS_PRERELEASE="true"
fi

TAG="${NAMESPACE}/v${NEXT}"

if git -C "$RTC_REPO_ROOT" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
    echo "Error: tag '${TAG}' already exists" >&2
    exit 1
fi

emit() {
    local key="$1" value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
    fi
}

emit "current" "${CURRENT:-none}"
emit "next" "$NEXT"
emit "tag" "$TAG"
emit "is_prerelease" "$IS_PRERELEASE"

{
    echo "Namespace:     $NAMESPACE"
    echo "Current:       ${CURRENT:-none}"
    echo "Bump:          $BUMP"
    echo "Next:          $NEXT"
    echo "Tag:           $TAG"
    echo "Prerelease:    $IS_PRERELEASE"
} >&2
