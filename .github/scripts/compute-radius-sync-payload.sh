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
# compute-radius-sync-payload.sh
# -----------------------------------------------------------------------------
# Build the `repository_dispatch` client-payload that notify-radius.yaml sends
# to radius-project/radius so it can re-sync its default resource-type
# manifests.
#
# This implements the resource-types-contrib side of the "sync default resource
# types without a fake Go module" design (radius PR #12236), Phase A:
#
#   * Option 3 (pinned git-ref) + Option 6 (automated PR sync), together the
#     "hybrid": the payload carries an immutable pin (a commit SHA on the moving
#     channel, or a release tag on the release channel) that the Radius bot
#     records as `source.ref` / `sources[].ref` and re-syncs via a reviewable PR.
#   * Per-namespace variant: instead of one repository-wide pin, the payload
#     lists exactly the `Radius.<Category>` namespaces affected by this event,
#     each with its ref, so Radius can advance only the namespaces that changed.
#
# Channels:
#   * edge    -> push to `main`. Ref is the pushed commit SHA (immutable, even
#                though it is repository-wide in Phase A). Affected namespaces
#                are derived from the manifest YAML files changed in the push.
#   * release -> a published release. Ref is the release tag. A scope-prefixed
#                tag (e.g. `Compute/containers/v0.1.0` or `Radius.Data/v0.2.0`)
#                affects just that namespace; a plain `vX.Y.Z` tag affects all.
#
# Inputs (environment variables, normally supplied by the workflow):
#   EVENT_NAME    github.event_name           ("push" | "release")
#   BEFORE_SHA    github.event.before         (push only)
#   AFTER_SHA     github.sha                  (push)
#   RELEASE_TAG   github.event.release.tag_name (release only)
#   CONTRIB_REPO  github.repository           (default: radius-project/resource-types-contrib)
#   ACTOR         github.actor
#   REPO_ROOT     repository root             (default: git toplevel, else CWD)
#   GITHUB_OUTPUT path for step outputs       (optional; when unset, outputs go
#                                              to stderr only)
#
# Outputs (written to $GITHUB_OUTPUT when set):
#   channel          the resolved channel ("edge" | "release")
#   ref              the immutable pin (commit SHA or release tag)
#   namespace_count  number of affected namespaces (0 => nothing to dispatch)
#   affected         comma-separated affected namespaces
#   payload          compact JSON client-payload (only when namespace_count > 0)
#
# Usage:
#   EVENT_NAME=push BEFORE_SHA=<sha> AFTER_SHA=<sha> ./compute-radius-sync-payload.sh
#   EVENT_NAME=release RELEASE_TAG=Compute/containers/v0.1.0 ./compute-radius-sync-payload.sh
# =============================================================================

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
EVENT_NAME="${EVENT_NAME:-push}"
BEFORE_SHA="${BEFORE_SHA:-}"
AFTER_SHA="${AFTER_SHA:-}"
RELEASE_TAG="${RELEASE_TAG:-}"
CONTRIB_REPO="${CONTRIB_REPO:-radius-project/resource-types-contrib}"
ACTOR="${ACTOR:-}"
RELEASE_PRERELEASE="${RELEASE_PRERELEASE:-}"

ZERO_SHA="0000000000000000000000000000000000000000"

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' is required but was not found on PATH" >&2
    exit 1
fi

# Namespace/category enumeration is shared with the release tooling so there is
# a single definition of what a namespace is.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-namespaces.sh
source "$SCRIPT_DIR/lib-namespaces.sh"

# Reason recorded when nothing is dispatched (surfaced in the workflow summary).
REASON=""

# Accumulator for affected namespaces (deduplicated, insertion order preserved).
declare -a AFFECTED_NS=()
add_namespace() {
    local ns="$1" existing
    for existing in "${AFFECTED_NS[@]:-}"; do
        [[ "$existing" == "$ns" ]] && return 0
    done
    AFFECTED_NS+=("$ns")
}

add_all_namespaces() {
    local cat
    while IFS= read -r cat; do
        [[ -z "$cat" ]] && continue
        add_namespace "Radius.$cat"
    done < <(rtc_list_folders)
}

CHANNEL=""
REF=""

case "$EVENT_NAME" in
    release)
        CHANNEL="release"
        REF="$RELEASE_TAG"
        if [[ -z "$REF" ]]; then
            echo "Error: release event is missing a tag (RELEASE_TAG)" >&2
            exit 1
        fi
        if [[ "$RELEASE_PRERELEASE" == "true" ]]; then
            # Prereleases (rc/beta/...) are not synced: the edge channel already
            # tracks the same commits on main, and the release channel pins
            # stable tags only.
            REASON="prerelease"
        elif [[ "$REF" == */* ]]; then
            # Scope-prefixed tag: the first path segment names the scope.
            # Tolerate both "Compute/..." and "Radius.Compute/..." forms.
            scope="${REF%%/*}"
            scope="${scope#Radius.}"
            if rtc_is_category "$scope"; then
                add_namespace "Radius.$scope"
            else
                # A non-category scope (e.g. recipe-packs/...) is not a manifest
                # namespace, so nothing is dispatched.
                REASON="non-namespace-scope"
            fi
        else
            # Plain repository-wide tag (vX.Y.Z): every namespace advances.
            add_all_namespaces
        fi
        ;;
    push | "")
        CHANNEL="edge"
        REF="$AFTER_SHA"
        if [[ -z "$REF" ]]; then
            REF="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
        fi

        changed=""
        if [[ -n "$BEFORE_SHA" && "$BEFORE_SHA" != "$ZERO_SHA" && -n "$AFTER_SHA" ]]; then
            changed="$(git -C "$REPO_ROOT" diff --name-only "$BEFORE_SHA" "$AFTER_SHA" 2>/dev/null || true)"
        fi

        if [[ -n "$changed" ]]; then
            while IFS= read -r path; do
                [[ -z "$path" ]] && continue
                # Only resource-type manifest YAML changes drive a re-sync.
                case "$path" in
                    *.yaml | *.yml) ;;
                    *) continue ;;
                esac
                top="${path%%/*}"
                if rtc_is_excluded_dir "$top"; then
                    continue
                fi
                if rtc_is_category "$top"; then
                    add_namespace "Radius.$top"
                fi
            done <<<"$changed"
        else
            # No usable diff (new branch, shallow clone, or unrelated
            # force-push): fall back to the safe superset of all namespaces.
            add_all_namespaces
        fi
        ;;
    *)
        echo "Error: unsupported event '$EVENT_NAME' (expected 'push' or 'release')" >&2
        exit 1
        ;;
esac

COUNT="${#AFFECTED_NS[@]}"
AFFECTED_CSV="$(
    IFS=,
    echo "${AFFECTED_NS[*]:-}"
)"

PAYLOAD=""
if [[ "$COUNT" -gt 0 ]]; then
    namespaces_json="$(
        printf '%s\n' "${AFFECTED_NS[@]}" |
            jq -R -c --arg ref "$REF" 'select(length > 0) | {namespace: ., ref: $ref}' |
            jq -s -c '.'
    )"
    PAYLOAD="$(
        jq -c -n \
            --arg channel "$CHANNEL" \
            --arg repo "$CONTRIB_REPO" \
            --arg ref "$REF" \
            --arg actor "$ACTOR" \
            --argjson namespaces "$namespaces_json" \
            '{channel: $channel, contrib_repo: $repo, contrib_ref: $ref, namespaces: $namespaces, actor: $actor}'
    )"
fi

emit() {
    local key="$1" value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
    fi
}

if [[ "$COUNT" -eq 0 && -z "$REASON" ]]; then
    REASON="no-namespace-changes"
fi

emit "channel" "$CHANNEL"
emit "ref" "$REF"
emit "namespace_count" "$COUNT"
emit "affected" "$AFFECTED_CSV"
emit "reason" "$REASON"
if [[ "$COUNT" -gt 0 ]]; then
    emit "payload" "$PAYLOAD"
fi

{
    echo "Event:      $EVENT_NAME"
    echo "Channel:    $CHANNEL"
    echo "Ref:        $REF"
    echo "Namespaces: ${AFFECTED_CSV:-<none>} ($COUNT)"
    if [[ "$COUNT" -gt 0 ]]; then
        echo "Payload:    $PAYLOAD"
    else
        echo "Payload:    <none - skipped: ${REASON:-none}>"
    fi
} >&2
