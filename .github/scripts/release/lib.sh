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
# Shared helpers for the release tooling. Source this from the other scripts in
# this directory:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib.sh"
#
# Two kinds of units are released independently, each on its own tag series:
#
#   * namespace    `Radius.<Category>` (e.g. Radius.Data), mapping 1:1 to a
#                  top-level category directory (e.g. Data/).
#                  tag: Radius.<Category>/v<major>.<minor>.<patch>[-<prerelease>]
#   * recipe pack  a directory under recipepack/ (e.g. recipepack/kubernetes).
#                  tag: recipe-pack/<pack>/v<major>.<minor>.<patch>[-<prerelease>]
#
# In both cases git tags are the single source of truth for the current version
# -- there is no version file to keep in sync -- and a tag is always
# `<prefix>/v<version>`, where the prefix identifies the released unit.
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

# Recipe packs live one directory below this root. Their tags carry a
# `recipe-pack/` prefix so they never collide with the namespace tag series and
# so the Radius sync tooling can recognize them as a non-namespace scope.
RTC_RECIPE_PACK_ROOT="${RTC_RECIPE_PACK_ROOT:-recipepack}"
RTC_RECIPE_PACK_TAG_PREFIX="recipe-pack"

# Print the releasable recipe packs (directory names under recipepack/), one per
# line, sorted. A directory is only treated as a pack when it holds a Bicep
# template, so unrelated folders are never mistaken for a pack.
rtc_list_recipe_packs() {
    local dir
    [[ -d "$RTC_REPO_ROOT/$RTC_RECIPE_PACK_ROOT" ]] || return 0
    while IFS= read -r dir; do
        if compgen -G "$dir/*.bicep" >/dev/null; then
            echo "${dir##*/}"
        fi
    done < <(find "$RTC_REPO_ROOT/$RTC_RECIPE_PACK_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
}

# True if the argument is a known recipe pack (e.g. "kubernetes").
rtc_is_recipe_pack() {
    local pack="$1" candidate
    while IFS= read -r candidate; do
        [[ "$candidate" == "$pack" ]] && return 0
    done < <(rtc_list_recipe_packs)
    return 1
}

# Map a recipe pack to its tag prefix and directory
# (e.g. kubernetes -> recipe-pack/kubernetes, recipepack/kubernetes).
rtc_recipe_pack_tag_prefix() { echo "${RTC_RECIPE_PACK_TAG_PREFIX}/$1"; }
rtc_recipe_pack_dir() { echo "${RTC_RECIPE_PACK_ROOT}/$1"; }

# Print the highest existing STABLE version (X.Y.Z, no prerelease suffix) for a
# tag series, derived from git tags. `prefix` identifies the released unit (e.g.
# `Radius.Data` or `recipe-pack/kubernetes`) and tags are `<prefix>/v<version>`.
# Empty when the unit has no release yet.
rtc_latest_version() {
    local prefix="$1" tag version
    git -C "$RTC_REPO_ROOT" tag --list "${prefix}/v*" 2>/dev/null |
        while IFS= read -r tag; do
            version="${tag#"${prefix}/v"}"
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

# Write a `key=value` step output when running under GitHub Actions; a no-op
# locally so the same scripts work in both places.
rtc_emit() {
    local key="$1" value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
    fi
}

# -----------------------------------------------------------------------------
# Release bundles
#
# A bundle is a deterministic tarball of repository files laid out under their
# repo-relative paths (so it extracts back into the same tree) plus a
# checksums.txt. Shared by the namespace and recipe pack bundle builders:
#
#   rtc_bundle_begin
#   rtc_bundle_add_file "<absolute path under the repo root>"
#   rtc_bundle_create "$OUT_DIR" "<asset name>.tar.gz"
#
# rtc_bundle_create sets RTC_BUNDLE_ASSET and RTC_BUNDLE_CHECKSUMS.
# -----------------------------------------------------------------------------
RTC_BUNDLE_STAGING=""
RTC_BUNDLE_ASSET=""
RTC_BUNDLE_CHECKSUMS=""

rtc_bundle_begin() {
    RTC_BUNDLE_STAGING="$(mktemp -d)"
    trap 'rm -rf "$RTC_BUNDLE_STAGING"' EXIT
}

rtc_bundle_add_file() {
    local src="$1" rel
    rel="${src#"$RTC_REPO_ROOT"/}"
    mkdir -p "$RTC_BUNDLE_STAGING/$(dirname "$rel")"
    cp "$src" "$RTC_BUNDLE_STAGING/$rel"
}

rtc_bundle_create() {
    local out_dir="$1" asset_name="$2" out_dir_abs
    mkdir -p "$out_dir"
    out_dir_abs="$(cd "$out_dir" && pwd)"
    RTC_BUNDLE_ASSET="$out_dir_abs/$asset_name"

    # Deterministic archive: fixed order/mtime/ownership so the checksum is
    # stable across rebuilds of the same content.
    tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
        -czf "$RTC_BUNDLE_ASSET" -C "$RTC_BUNDLE_STAGING" .

    # shellcheck disable=SC2034 # read by the sourcing bundle script
    RTC_BUNDLE_CHECKSUMS="$out_dir_abs/checksums.txt"
    (cd "$out_dir_abs" && sha256sum "$asset_name" >"checksums.txt")
}
