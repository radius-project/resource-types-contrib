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
# to radius-project/radius so it can re-sync what it consumes from this
# repository.
#
# This implements the resource-types-contrib side of the "sync default resource
# types without a fake Go module" design (radius PR #12236), Phase A:
#
#   * Option 3 (pinned git-ref) + Option 6 (automated PR sync), together the
#     "hybrid": the payload carries an immutable stable release tag, or a
#     commit SHA as the edge fallback until that unit has its first stable
#     release. The Radius bot records the pin in
#     `deploy/manifest/defaults.yaml` and re-syncs via a reviewable PR.
#   * Per-unit variant: instead of one repository-wide pin, the payload lists
#     exactly the units affected by this event, so Radius advances only what
#     changed. Two kinds of units are dispatched, matching the two pin sections
#     Radius keeps in defaults.yaml (radius PR #12567):
#       - namespaces    `Radius.<Category>` manifest namespaces -> resourceTypes[]
#       - recipe packs  directories under recipe-packs/         -> recipePacks[]
#
# Channels:
#   * edge    -> a push to `main`, but only for changed units with no stable
#                release tag yet. Ref is the pushed commit SHA. Once a unit has
#                a stable release, pushes can no longer advance it.
#   * release -> a stable release tag. A scope-prefixed tag affects just that
#                unit -- `Radius.Data/v0.2.0` a namespace or
#                `recipe-pack/azure/v0.2.0` a recipe pack -- while a plain
#                `vX.Y.Z` tag affects every unit.
#
# Payload shape (consumed by the Radius contrib-update-resource-types.yaml
# workflow, which accepts `namespace` as a legacy alias for `name`):
#   {
#     channel, contrib_repo, contrib_ref, actor,
#     namespaces:   [ {name, namespace, ref}, ... ],
#     recipe_packs: [ {name, ref}, ... ]
#   }
#
# Inputs (environment variables, normally supplied by the workflow):
#   EVENT_NAME    github.event_name           ("push" | "release")
#   BEFORE_SHA    github.event.before         (push only)
#   AFTER_SHA     github.sha                  (push only)
#   RELEASE_TAG   github.event.release.tag_name (release only)
#   RELEASE_PRERELEASE github.event.release.prerelease
#   CONTRIB_REPO  github.repository           (default: radius-project/resource-types-contrib)
#   ACTOR         github.actor
#   REPO_ROOT     repository root             (default: git toplevel, else CWD)
#   GITHUB_OUTPUT path for step outputs       (optional; when unset, outputs go
#                                              to stderr only)
#
# Outputs (written to $GITHUB_OUTPUT when set):
#   channel                "edge" | "release"
#   ref                    the immutable commit SHA or release tag
#   namespace_count        number of affected namespaces
#   affected               comma-separated affected namespaces
#   recipe_pack_count      number of affected recipe packs
#   affected_recipe_packs  comma-separated affected recipe packs
#   unit_count             total affected units (0 => nothing to dispatch)
#   reason                 why nothing was dispatched (only when unit_count is 0)
#   payload                compact JSON client-payload (only when unit_count > 0)
#
# Usage:
#   EVENT_NAME=push BEFORE_SHA=<sha> AFTER_SHA=<sha> ./compute-radius-sync-payload.sh
#   EVENT_NAME=release RELEASE_TAG=Radius.Compute/v0.1.0 ./compute-radius-sync-payload.sh
#   EVENT_NAME=release RELEASE_TAG=recipe-pack/azure/v0.1.0 ./compute-radius-sync-payload.sh
# =============================================================================

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
EVENT_NAME="${EVENT_NAME:-release}"
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
STABLE_UNITS_SKIPPED=0

# Accumulators for affected units (deduplicated, insertion order preserved).
declare -a AFFECTED_NS=()
declare -a AFFECTED_PACKS=()

add_namespace() {
    local ns="$1" existing
    for existing in "${AFFECTED_NS[@]:-}"; do
        [[ "$existing" == "$ns" ]] && return 0
    done
    AFFECTED_NS+=("$ns")
}

add_recipe_pack() {
    local pack="$1" existing
    for existing in "${AFFECTED_PACKS[@]:-}"; do
        [[ "$existing" == "$pack" ]] && return 0
    done
    AFFECTED_PACKS+=("$pack")
}

add_all_namespaces() {
    local cat
    while IFS= read -r cat; do
        [[ -z "$cat" ]] && continue
        add_namespace "Radius.$cat"
    done < <(rtc_list_folders)
}

add_all_recipe_packs() {
    local pack
    while IFS= read -r pack; do
        [[ -z "$pack" ]] && continue
        add_recipe_pack "$pack"
    done < <(rtc_list_recipe_packs)
}

is_stable_version_tag() {
    local tag="$1"
    [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

has_stable_tag_for_prefix() {
    local prefix="$1" tag
    while IFS= read -r tag; do
        if is_stable_version_tag "${tag#"$prefix"/}"; then
            return 0
        fi
    done < <(git -C "$REPO_ROOT" tag --list "${prefix}/v*")
    return 1
}

has_repository_wide_stable_tag() {
    local tag
    while IFS= read -r tag; do
        if is_stable_version_tag "$tag"; then
            return 0
        fi
    done < <(git -C "$REPO_ROOT" tag --list 'v*')
    return 1
}

has_stable_namespace_release() {
    local namespace="$1" category="${1#Radius.}"
    has_repository_wide_stable_tag ||
        has_stable_tag_for_prefix "$namespace" ||
        has_stable_tag_for_prefix "$category"
}

has_stable_recipe_pack_release() {
    local pack="$1"
    has_repository_wide_stable_tag ||
        has_stable_tag_for_prefix "$(rtc_recipe_pack_tag_prefix "$pack")"
}

add_edge_namespace() {
    local namespace="$1"
    if has_stable_namespace_release "$namespace"; then
        STABLE_UNITS_SKIPPED=$((STABLE_UNITS_SKIPPED + 1))
        return 0
    fi
    add_namespace "$namespace"
}

add_edge_recipe_pack() {
    local pack="$1"
    if has_stable_recipe_pack_release "$pack"; then
        STABLE_UNITS_SKIPPED=$((STABLE_UNITS_SKIPPED + 1))
        return 0
    fi
    add_recipe_pack "$pack"
}

add_all_edge_namespaces() {
    local category
    while IFS= read -r category; do
        [[ -z "$category" ]] && continue
        add_edge_namespace "Radius.$category"
    done < <(rtc_list_folders)
}

add_all_edge_recipe_packs() {
    local pack
    while IFS= read -r pack; do
        [[ -z "$pack" ]] && continue
        add_edge_recipe_pack "$pack"
    done < <(rtc_list_recipe_packs)
}

# Read manifests from each side of the push diff so deletes and namespace
# renames still identify the unit that Radius may need to refresh.
is_resource_type_yaml_at_ref() {
    local ref="$1" path="$2" expected_namespace="$3" contents
    [[ -n "$ref" && -n "$path" ]] || return 1
    contents="$(git -C "$REPO_ROOT" show "${ref}:${path}" 2>/dev/null)" || return 1
    sed -nE \
        's/^namespace:[[:space:]]*(Radius\.[^[:space:]#]+)[[:space:]]*$/\1/p' \
        <<<"$contents" | grep -Fxq "$expected_namespace" &&
        grep -qE '^types:' <<<"$contents"
}

add_edge_namespace_for_path_at_ref() {
    local path="$1" ref="$2" top
    top="${path%%/*}"
    rtc_is_excluded_dir "$top" && return 0

    case "$path" in
        *.yaml | *.yml)
            if is_resource_type_yaml_at_ref "$ref" "$path" "Radius.$top"; then
                add_edge_namespace "Radius.$top"
            fi
            ;;
        "$top"/*/recipes/*)
            # Recipe-only changes also need the namespace SHA pin because a
            # released rad uses that SHA as the recipe OCI tag.
            if rtc_is_category "$top"; then
                add_edge_namespace "Radius.$top"
            fi
            ;;
    esac
}

# Recipe pack membership is path-based so deletions and renames still identify
# the old pack. Radius ignores names it does not register.
add_edge_recipe_pack_for_path() {
    local path="$1" rest pack
    [[ "$path" == "$RTC_RECIPE_PACK_ROOT"/* ]] || return 0
    rest="${path#"$RTC_RECIPE_PACK_ROOT"/}"
    [[ "$rest" == */* ]] || return 0
    pack="${rest%%/*}"
    case "$pack" in
        "" | *[!A-Za-z0-9._-]*) return 0 ;;
    esac
    add_edge_recipe_pack "$pack"
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
            # Defense in depth: the workflow subscribes only to stable
            # `released` events, and the payload generator enforces that
            # contract independently.
            REASON="prerelease"
        elif ! is_stable_version_tag "${REF##*/}"; then
            # Do not trust the release classification alone: GitHub allows a
            # release with any tag name to be marked stable. Only this
            # repository's exact stable SemVer tag forms may notify Radius.
            REASON="invalid-release-tag"
        elif [[ "$REF" == "$RTC_RECIPE_PACK_TAG_PREFIX"/*/* ]]; then
            # Recipe pack tag: recipe-pack/<pack>/vX.Y.Z.
            pack_ref="${REF#"$RTC_RECIPE_PACK_TAG_PREFIX"/}"
            pack="${pack_ref%/*}"
            if [[ "$pack" == */* ]]; then
                REASON="invalid-release-tag"
            elif rtc_is_recipe_pack "$pack"; then
                add_recipe_pack "$pack"
            else
                REASON="unknown-recipe-pack"
            fi
        elif [[ "$REF" == */* ]]; then
            # Scope-prefixed tag: the first path segment names the scope.
            # Tolerate both "Compute/..." and "Radius.Compute/..." forms.
            scope="${REF%/*}"
            if [[ "$scope" == */* ]]; then
                REASON="invalid-release-tag"
            else
                scope="${scope#Radius.}"
            fi
            if [[ -z "$REASON" ]] && rtc_is_category "$scope"; then
                add_namespace "Radius.$scope"
            elif [[ -z "$REASON" ]]; then
                # A scope that is neither a namespace nor a recipe pack names
                # nothing Radius consumes, so nothing is dispatched.
                REASON="unknown-scope"
            fi
        else
            # Plain repository-wide tag (vX.Y.Z): every unit advances.
            add_all_namespaces
            add_all_recipe_packs
        fi
        ;;
    push)
        CHANNEL="edge"
        REF="$AFTER_SHA"
        if [[ -z "$REF" ]]; then
            REF="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
        fi
        if [[ -z "$REF" ]]; then
            echo "Error: push event is missing a commit SHA (AFTER_SHA)" >&2
            exit 1
        fi

        # A force-pushed before commit is not necessarily included by a full
        # checkout because it may no longer be reachable from a branch. GitHub
        # normally keeps the object fetchable by SHA for a while; recover it so
        # deletes and renames can still inspect the old side of the diff.
        if [[ "$BEFORE_SHA" =~ ^[0-9a-f]{40}$ && "$BEFORE_SHA" != "$ZERO_SHA" ]] &&
            ! git -C "$REPO_ROOT" cat-file -e "${BEFORE_SHA}^{commit}" 2>/dev/null; then
            git -C "$REPO_ROOT" fetch --no-tags --depth=1 origin "$BEFORE_SHA" \
                >/dev/null 2>&1 || true
        fi

        if [[ -n "$BEFORE_SHA" && "$BEFORE_SHA" != "$ZERO_SHA" && -n "$AFTER_SHA" ]] &&
            git -C "$REPO_ROOT" cat-file -e "${BEFORE_SHA}^{commit}" 2>/dev/null &&
            git -C "$REPO_ROOT" cat-file -e "${AFTER_SHA}^{commit}" 2>/dev/null; then
            while IFS= read -r -d '' status; do
                IFS= read -r -d '' old_path
                case "${status:0:1}" in
                    R | C)
                        IFS= read -r -d '' new_path
                        add_edge_namespace_for_path_at_ref "$old_path" "$BEFORE_SHA"
                        add_edge_namespace_for_path_at_ref "$new_path" "$AFTER_SHA"
                        add_edge_recipe_pack_for_path "$old_path"
                        add_edge_recipe_pack_for_path "$new_path"
                        ;;
                    *)
                        add_edge_namespace_for_path_at_ref "$old_path" "$BEFORE_SHA"
                        add_edge_namespace_for_path_at_ref "$old_path" "$AFTER_SHA"
                        add_edge_recipe_pack_for_path "$old_path"
                        ;;
                esac
            done < <(git -C "$REPO_ROOT" diff --name-status --find-renames -z "$BEFORE_SHA" "$AFTER_SHA")
        else
            # A new branch or force-push with no usable range falls back to all
            # current units that have not reached a stable release yet.
            add_all_edge_namespaces
            add_all_edge_recipe_packs
        fi
        ;;
    *)
        echo "Error: unsupported event '$EVENT_NAME' (expected 'push' or 'release')" >&2
        exit 1
        ;;
esac

NS_COUNT="${#AFFECTED_NS[@]}"
PACK_COUNT="${#AFFECTED_PACKS[@]}"
UNIT_COUNT=$((NS_COUNT + PACK_COUNT))
AFFECTED_NS_CSV="$(
    IFS=,
    echo "${AFFECTED_NS[*]:-}"
)"
AFFECTED_PACKS_CSV="$(
    IFS=,
    echo "${AFFECTED_PACKS[*]:-}"
)"

# Render unit names as a compact JSON array of pin objects. Namespace entries
# repeat the name under `namespace` as well: Radius reads `name` and keeps
# `namespace` as a legacy alias, so one payload satisfies both.
pins_json() {
    local with_alias="$1"
    shift
    printf '%s\n' "$@" |
        jq -R -c --arg ref "$REF" --argjson alias "$with_alias" \
            'select(length > 0) |
             if $alias then {name: ., namespace: ., ref: $ref} else {name: ., ref: $ref} end' |
        jq -s -c '.'
}

PAYLOAD=""
if [[ "$UNIT_COUNT" -gt 0 ]]; then
    PAYLOAD="$(
        jq -c -n \
            --arg channel "$CHANNEL" \
            --arg repo "$CONTRIB_REPO" \
            --arg ref "$REF" \
            --arg actor "$ACTOR" \
            --argjson namespaces "$(pins_json true "${AFFECTED_NS[@]:-}")" \
            --argjson recipe_packs "$(pins_json false "${AFFECTED_PACKS[@]:-}")" \
            '{channel: $channel, contrib_repo: $repo, contrib_ref: $ref,
              namespaces: $namespaces, recipe_packs: $recipe_packs, actor: $actor}'
    )"
fi

emit() {
    local key="$1" value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
    fi
}

if [[ "$UNIT_COUNT" -eq 0 && -z "$REASON" ]]; then
    if [[ "$STABLE_UNITS_SKIPPED" -gt 0 ]]; then
        REASON="stable-release-exists"
    else
        REASON="no-relevant-changes"
    fi
fi

emit "channel" "$CHANNEL"
emit "ref" "$REF"
emit "namespace_count" "$NS_COUNT"
emit "affected" "$AFFECTED_NS_CSV"
emit "recipe_pack_count" "$PACK_COUNT"
emit "affected_recipe_packs" "$AFFECTED_PACKS_CSV"
emit "unit_count" "$UNIT_COUNT"
emit "reason" "$REASON"
if [[ "$UNIT_COUNT" -gt 0 ]]; then
    emit "payload" "$PAYLOAD"
fi

{
    echo "Event:        $EVENT_NAME"
    echo "Channel:      $CHANNEL"
    echo "Ref:          $REF"
    echo "Namespaces:   ${AFFECTED_NS_CSV:-<none>} ($NS_COUNT)"
    echo "Recipe packs: ${AFFECTED_PACKS_CSV:-<none>} ($PACK_COUNT)"
    if [[ "$UNIT_COUNT" -gt 0 ]]; then
        echo "Payload:      $PAYLOAD"
    else
        echo "Payload:      <none - skipped: ${REASON:-none}>"
    fi
} >&2
