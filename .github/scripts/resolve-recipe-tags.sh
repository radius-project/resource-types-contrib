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
# uses that SHA verbatim as the recipe's OCI tag (radius PR #12566). The pins in
# defaults.yaml come from the dispatches notify-radius.yaml sends, so every SHA
# this repository can dispatch has to already exist as a tag in the registry --
# otherwise a released CLI resolves a reference that 404s. The SHA tag is
# therefore unconditional, immutable, and republishing it is a no-op because
# identical Bicep produces an identical digest.
#
# The remaining tags are floating aliases layered on top and mirror the release
# lifecycle in notify-radius.yaml:
#   * edge      -> pushes to `main` and manual runs with no version.
#   * <version> -> manual dispatch with RELEASE_VERSION.
#   * latest    -> only for a stable RELEASE_VERSION; SemVer marks a prerelease
#                  with a `-`, so `latest` never resolves to an unreleased build.
#
# Inputs (environment variables):
#   COMMIT_SHA       required, full lowercase 40-character commit SHA
#   RELEASE_VERSION  optional, e.g. 0.51.0
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
