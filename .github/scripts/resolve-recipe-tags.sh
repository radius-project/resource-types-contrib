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
# resolve-recipe-tags.sh
# -----------------------------------------------------------------------------
# Resolve the OCI tags one Bicep recipe publish should push.
#
# Every publish carries the full commit SHA it was built from. That SHA tag is
# the contract with Radius: a released `rad` resolves a resource type's
# namespace to the commit SHA that deploy/manifest/defaults.yaml pins for it and
# uses that SHA verbatim as the recipe's OCI tag (radius PR #12566). Before a
# stable namespace release notifies Radius, release-namespace.yaml invokes the
# publisher for that exact SHA and fails closed if it cannot be pushed. The SHA
# tag is therefore unconditional and immutable; republishing it is a no-op
# because identical Bicep produces an identical digest.
#
# The remaining tags are aliases layered on top of that immutable coordinate:
#   * edge      -> pushes to `main` and manual runs with no version.
#   * <version> -> manual dispatch with RELEASE_VERSION.
#   * latest    -> only for a stable RELEASE_VERSION; SemVer marks a prerelease
#                  with a `-`, so `latest` never resolves to an unreleased build.
#
# Inputs (environment variables):
#   COMMIT_SHA       required, full lowercase 40-character commit SHA
#   RELEASE_VERSION  optional SemVer without a leading v, e.g. 0.51.0 or
#                    0.51.0-rc.1
#   PIN_ONLY         optional, "true" publishes the SHA tag alone
#   GITHUB_OUTPUT    optional; when set, `tags` is written there too
#
# Output:
#   The space-separated tag list on stdout (and as the `tags` step output).
#
# Usage:
#   COMMIT_SHA=$GITHUB_SHA ./.github/scripts/resolve-recipe-tags.sh
# =============================================================================

set -euo pipefail

COMMIT_SHA="${COMMIT_SHA:?COMMIT_SHA is required}"
RELEASE_VERSION="${RELEASE_VERSION:-}"
PIN_ONLY="${PIN_ONLY:-false}"

# Radius compares this tag against the SHA it pinned, so an abbreviated or
# uppercase SHA can never match and would silently publish an unreachable tag.
if [[ ! "$COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: COMMIT_SHA must be a full lowercase 40-character commit SHA, got '$COMMIT_SHA'" >&2
    exit 1
fi

is_valid_release_version() {
    local version="$1" core prerelease identifier
    local -a identifiers=()

    core="${version%%-*}"
    [[ "$core" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || return 1
    [[ "$version" == *-* ]] || return 0

    prerelease="${version#*-}"
    [[ -n "$prerelease" ]] || return 1
    [[ "$prerelease" =~ ^[0-9A-Za-z.-]+$ ]] || return 1
    [[ "$prerelease" != .* && "$prerelease" != *. && "$prerelease" != *..* ]] || return 1

    IFS='.' read -r -a identifiers <<<"$prerelease"
    for identifier in "${identifiers[@]}"; do
        if [[ "$identifier" =~ ^[0-9]+$ && "$identifier" =~ ^0[0-9]+$ ]]; then
            return 1
        fi
    done
}

if [[ -n "$RELEASE_VERSION" ]] && ! is_valid_release_version "$RELEASE_VERSION"; then
    echo "Error: RELEASE_VERSION must be a SemVer version without a leading 'v', got '$RELEASE_VERSION'" >&2
    exit 1
fi

tags=("$COMMIT_SHA")

if [[ "$PIN_ONLY" != "true" ]]; then
    if [[ -z "$RELEASE_VERSION" ]]; then
        tags+=("edge")
    else
        tags+=("$RELEASE_VERSION")
        if [[ "$RELEASE_VERSION" != *-* ]]; then
            tags+=("latest")
        fi
    fi
fi

TAGS="${tags[*]}"
echo "$TAGS"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'tags=%s\n' "$TAGS" >>"$GITHUB_OUTPUT"
fi
