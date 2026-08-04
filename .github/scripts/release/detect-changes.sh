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
# detect-changes.sh
# -----------------------------------------------------------------------------
# Answer one question for a single released unit: is there anything new to
# release? This repository is a monorepo whose namespaces and recipe packs are
# versioned independently, so the answer is scoped to the files that unit
# actually ships -- churn anywhere else in the repository must not push a
# namespace or a recipe pack to a new version.
#
# The comparison is against the commit the unit's latest STABLE release tag
# points at, so it is a content comparison rather than a commit count: a change
# that was reverted before the release leaves nothing to publish and is
# reported as unchanged. Prereleases are deliberately not used as the baseline
# -- they are staging artifacts, and promoting one to a stable release must
# never be blocked for lack of further changes.
#
# Release scope:
#   * namespace    the whole category directory, minus the per-type `test/`
#                  applications. Manifests and READMEs go into the release
#                  bundle, and the recipes beside them are published to GHCR
#                  under the release commit's SHA -- the tag Radius resolves
#                  this namespace pin to (radius PR #12566) -- so a recipe-only
#                  change is a releasable change. Test applications never ship.
#   * recipe pack  the pack directory (its Bicep templates and README).
#
# Inputs (environment variables):
#   NAMESPACE     a namespace to release, e.g. Radius.Data
#   RECIPE_PACK   a recipe pack to release, e.g. kubernetes
#                 (exactly one of NAMESPACE or RECIPE_PACK is required)
#   REF           the commit to release (default: HEAD)
#   REPO_ROOT     repository root (default: git toplevel, else CWD)
#   GITHUB_OUTPUT optional; when set, outputs are written there too
#
# Outputs (stdout summary + $GITHUB_OUTPUT):
#   changed       "true" | "false"
#   previous_tag  the release tag compared against, or "none"
#   reason        no-previous-release | previous-release-unreachable |
#                 changes-detected | no-changes
#   count         number of files in the release scope this run would publish:
#                 the diff against the baseline, or -- when there is no usable
#                 baseline to diff against -- every file in the scope. Read it
#                 together with `reason`.
#
# Usage:
#   NAMESPACE=Radius.Data ./.github/scripts/release/detect-changes.sh
#   RECIPE_PACK=kubernetes ./.github/scripts/release/detect-changes.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/release/lib.sh
source "$SCRIPT_DIR/lib.sh"

REF="${REF:-HEAD}"

rtc_resolve_unit

# The git pathspecs covering this unit's release scope.
case "$RTC_UNIT_KIND" in
    namespace)
        FOLDER="$(rtc_folder_for_namespace "$RTC_UNIT")"
        PATHSPECS=("$FOLDER" ":(exclude,glob)${FOLDER}/*/test/**")
        ;;
    recipe-pack)
        PATHSPECS=("$(rtc_recipe_pack_dir "$RTC_UNIT")")
        ;;
    *)
        # An empty pathspec would compare the whole repository, which is exactly
        # what this script exists to avoid.
        echo "Error: unknown unit kind '$RTC_UNIT_KIND'" >&2
        exit 1
        ;;
esac

PREVIOUS_TAG="$(rtc_latest_tag "$RTC_UNIT_TAG_PREFIX")"
CHANGED="true"
REASON=""

if [[ -z "$PREVIOUS_TAG" ]]; then
    REASON="no-previous-release"
elif ! git -C "$RTC_REPO_ROOT" rev-parse -q --verify "${PREVIOUS_TAG}^{commit}" >/dev/null 2>&1; then
    # Fail open. A baseline this checkout cannot see (shallow clone, deleted or
    # unfetched tag) is not evidence that nothing changed, and skipping a real
    # release is worse than cutting a redundant one.
    REASON="previous-release-unreachable"
fi

if [[ -n "$REASON" ]]; then
    # No usable baseline, so compare against the empty tree: every file the unit
    # ships reads as added. That keeps a single diff path -- identical pathspec
    # semantics -- and reports the release scope instead of a bare "0 files",
    # which would contradict the `changed=true` these cases fail open with.
    BASELINE="$(git -C "$RTC_REPO_ROOT" hash-object -t tree /dev/null)"
else
    BASELINE="$PREVIOUS_TAG"
fi

CHANGED_FILES="$(git -C "$RTC_REPO_ROOT" diff --name-only \
    "$BASELINE" "$REF" -- "${PATHSPECS[@]}")"
COUNT=0
if [[ -n "$CHANGED_FILES" ]]; then
    COUNT="$(grep -c '' <<<"$CHANGED_FILES")"
fi

if [[ -z "$REASON" ]]; then
    if [[ "$COUNT" -gt 0 ]]; then
        REASON="changes-detected"
    else
        CHANGED="false"
        REASON="no-changes"
    fi
fi

rtc_emit "changed" "$CHANGED"
rtc_emit "previous_tag" "${PREVIOUS_TAG:-none}"
rtc_emit "reason" "$REASON"
rtc_emit "count" "$COUNT"

{
    printf '%-14s %s\n' "$RTC_UNIT_LABEL" "$RTC_UNIT"
    printf '%-14s %s\n' "Baseline:" "${PREVIOUS_TAG:-none}"
    printf '%-14s %s\n' "Ref:" "$REF"
    printf '%-14s %s\n' "Changed:" "$CHANGED"
    printf '%-14s %s\n' "Reason:" "$REASON"
    printf '%-14s %s\n' "Files:" "$COUNT"
    if [[ -n "$CHANGED_FILES" ]]; then
        head -n 20 <<<"$CHANGED_FILES" | sed 's/^/  - /'
        if [[ "$COUNT" -gt 20 ]]; then
            echo "  - ... and $((COUNT - 20)) more"
        fi
    fi
} >&2
