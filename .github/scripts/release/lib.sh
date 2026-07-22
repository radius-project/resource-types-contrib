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
# lib.sh
# -----------------------------------------------------------------------------
# Shared helpers for the per-namespace release tooling. Source this from the
# other scripts in this directory:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib.sh"
#
# A "namespace" is `Radius.<Category>` (e.g. Radius.Data) and maps 1:1 to a
# top-level category directory (e.g. Data/). Each namespace is versioned and
# tagged independently: tags are `Radius.<Category>/v<major>.<minor>.<patch>`
# (optionally with a `-<prerelease>` suffix), and git tags are the single source
# of truth for the current version -- there is no version file to keep in sync.
# =============================================================================

# Guard against double-sourcing.
if [[ -n "${RTC_RELEASE_LIB_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
RTC_RELEASE_LIB_SOURCED=1

# Namespace enumeration and folder<->namespace mapping are shared with the
# Radius sync tooling so there is a single source of truth.
RTC_RELEASE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-namespaces.sh
source "$RTC_RELEASE_LIB_DIR/../lib-namespaces.sh"

# Print the highest existing STABLE version (X.Y.Z, no prerelease suffix) for a
# namespace, derived from git tags. Empty when the namespace has no release yet.
rtc_latest_version() {
    local ns="$1" tag version
    git -C "$RTC_REPO_ROOT" tag --list "${ns}/v*" 2>/dev/null |
        while IFS= read -r tag; do
            version="${tag#"${ns}/v"}"
            if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "$version"
            fi
        done |
        sort -V | tail -n1
}

# Bump a base X.Y.Z version by patch|minor|major. Any prerelease suffix on the
# base is dropped before bumping.
rtc_semver_bump() {
    local base="${1%%-*}" bump="$2" major minor patch
    IFS='.' read -r major minor patch <<<"$base"
    major="${major:-0}"
    minor="${minor:-0}"
    patch="${patch:-0}"
    case "$bump" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
        *)
            echo "Error: invalid bump '$bump' (expected patch|minor|major)" >&2
            return 1
            ;;
    esac
    echo "${major}.${minor}.${patch}"
}

# True when label is a valid SemVer prerelease value. Identifiers are separated
# by dots, contain only ASCII alphanumerics and hyphens, and numeric identifiers
# must not contain leading zeroes.
rtc_is_valid_prerelease() {
    local label="$1" identifier
    local -a identifiers=()
    [[ -n "$label" ]] || return 1
    [[ "$label" =~ ^[0-9A-Za-z.-]+$ ]] || return 1
    [[ "$label" != .* && "$label" != *. && "$label" != *..* ]] || return 1

    IFS='.' read -r -a identifiers <<<"$label"
    for identifier in "${identifiers[@]}"; do
        [[ "$identifier" =~ ^[0-9A-Za-z-]+$ ]] || return 1
        if [[ "$identifier" =~ ^[0-9]+$ && "$identifier" =~ ^0[0-9]+$ ]]; then
            return 1
        fi
    done
    return 0
}
