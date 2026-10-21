#!/bin/bash

# ------------------------------------------------------------
# Copyright 2026 The Radius Authors.
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
# prepare-release-candidate-sources.sh
# -----------------------------------------------------------------------------
# Replace the resource types, recipes, and Recipe Packs in this checkout with
# the released revisions a Radius release (candidate) ships with, so the
# nightly test scripts exercise exactly what that release installs.
#
# A Radius release records what it consumes from this repository in
# deploy/manifest/defaults.yaml at its `v<version>` tag:
#   resourceTypes[]  name: Radius.<Category>, ref: <commit SHA>
#   recipePacks[]    name: <pack folder>,     ref: <commit SHA>
#
# For each pin this script:
#   * restores `<Category>/` or `recipe-packs/<pack>/` from the pinned commit,
#     replacing the checked-out copy. Namespaces and packs the release does not
#     pin are removed, so only released content is built and tested.
#   * rewrites every repository-owned Recipe source in the restored packs
#     (`ghcr.io/radius-project/...:<tag>`) to the commit SHA its namespace is
#     pinned to. A released `rad` resolves recipes the same way (radius PR
#     #12566), and publish-bicep-recipes.yaml publishes that SHA tag before a
#     namespace release exists, so the tests pull the published recipes.
#
# The CI scripts under .github/ are left untouched: the current test tooling
# runs against the released content.
#
# Inputs (environment variables):
#   RADIUS_VERSION   required, Radius release version, e.g. 0.61.0-rc1
#                    (a leading `v` is accepted)
#   DEFAULTS_FILE    optional local defaults.yaml to read instead of
#                    downloading it from the Radius release tag (used by tests)
#   RADIUS_REPO      optional, default radius-project/radius
#   GIT_REMOTE       optional, remote to fetch pinned commits from (default origin)
#   REPO_ROOT        repository root (default: git toplevel, else CWD)
#   GITHUB_OUTPUT    optional; when set, outputs are written there too
#   GITHUB_STEP_SUMMARY optional; when set, a pin table is appended
#
# Outputs:
#   radius_version   the normalized version, e.g. 0.61.0-rc1
#   radius_tag       the Radius tag the pins were read from, e.g. v0.61.0-rc1
#
# Usage:
#   RADIUS_VERSION=0.61.0-rc1 ./.github/scripts/release/prepare-release-candidate-sources.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/release/lib.sh
source "$SCRIPT_DIR/lib.sh"

RADIUS_VERSION="${RADIUS_VERSION:-}"
DEFAULTS_FILE="${DEFAULTS_FILE:-}"
RADIUS_REPO="${RADIUS_REPO:-radius-project/radius}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
readonly SOURCE_REPO="github.com/radius-project/resource-types-contrib"
readonly REPO_RECIPE_SOURCE_PREFIX="ghcr.io/radius-project/"

version="${RADIUS_VERSION#v}"
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "Error: RADIUS_VERSION must be a Radius release version such as 0.61.0-rc1, got '$RADIUS_VERSION'" >&2
    exit 1
fi
radius_tag="v${version}"

command -v yq >/dev/null 2>&1 || {
    echo "Error: yq is required" >&2
    exit 1
}

if [[ -z "$DEFAULTS_FILE" ]]; then
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rtc-rc-sources-XXXXXX")"
    trap 'rm -rf "$tmp_dir"' EXIT
    DEFAULTS_FILE="$tmp_dir/defaults.yaml"
    url="https://raw.githubusercontent.com/${RADIUS_REPO}/${radius_tag}/deploy/manifest/defaults.yaml"
    echo "==> Reading pins from $url" >&2
    if ! curl -fsSL "$url" -o "$DEFAULTS_FILE"; then
        echo "Error: could not download defaults.yaml for Radius ${radius_tag}. Is the version released?" >&2
        exit 1
    fi
fi

# Print "<name>\t<ref>" for one defaults.yaml section after validating each pin.
read_pins() {
    local section="$1" name repo ref
    yq -r ".${section} // [] | .[] | [.name // \"\", .repo // \"\", .ref // \"\"] | @tsv" "$DEFAULTS_FILE" |
        while IFS=$'\t' read -r name repo ref; do
            if [[ -z "$name" ]]; then
                echo "Error: ${section} entry without a name in defaults.yaml" >&2
                return 1
            fi
            if [[ "$repo" != "$SOURCE_REPO" ]]; then
                echo "Error: ${section} pin '$name' uses repo '$repo'; only $SOURCE_REPO is supported" >&2
                return 1
            fi
            if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
                echo "Error: ${section} pin '$name' has ref '$ref'; expected a full commit SHA" >&2
                return 1
            fi
            printf '%s\t%s\n' "$name" "$ref"
        done
}

namespace_pins="$(read_pins resourceTypes)"
pack_pins="$(read_pins recipePacks)"

if [[ -z "$namespace_pins" || -z "$pack_pins" ]]; then
    echo "Error: Radius ${radius_tag} pins no resource type namespaces or no Recipe Packs" >&2
    exit 1
fi

# Fetch every pinned commit that is not already available locally.
while IFS= read -r ref; do
    if ! git -C "$RTC_REPO_ROOT" cat-file -e "${ref}^{commit}" 2>/dev/null; then
        echo "==> Fetching $ref" >&2
        git -C "$RTC_REPO_ROOT" fetch --quiet --no-tags --depth=1 "$GIT_REMOTE" "$ref"
    fi
done < <(printf '%s\n%s\n' "$namespace_pins" "$pack_pins" | cut -f2 | sort -u)

# Restore one repository path from a pinned commit, replacing what is there.
restore_path() {
    local path="$1" ref="$2"
    if [[ -z "$(git -C "$RTC_REPO_ROOT" ls-tree --name-only "$ref" -- "$path")" ]]; then
        echo "Error: '$path' does not exist at pinned commit $ref" >&2
        return 1
    fi
    rm -rf "${RTC_REPO_ROOT:?}/$path"
    git -C "$RTC_REPO_ROOT" restore --source="$ref" --worktree -- "$path"
}

# --- Namespaces -------------------------------------------------------------
existing_folders="$(rtc_list_folders)"
pinned_namespaces="$(cut -f1 <<<"$namespace_pins")"
while IFS= read -r folder; do
    [[ -z "$folder" ]] && continue
    if ! grep -Fxq "Radius.$folder" <<<"$pinned_namespaces"; then
        echo "==> Removing $folder/ (not pinned by Radius ${radius_tag})" >&2
        rm -rf "${RTC_REPO_ROOT:?}/$folder"
    fi
done <<<"$existing_folders"

while IFS=$'\t' read -r name ref; do
    folder="$(rtc_folder_for_namespace "$name")"
    echo "==> $name -> $folder/ @ $ref" >&2
    restore_path "$folder" "$ref"
done <<<"$namespace_pins"

# --- Recipe Packs -------------------------------------------------------------
while IFS= read -r pack; do
    [[ -z "$pack" ]] && continue
    rm -rf "${RTC_REPO_ROOT:?}/$(rtc_recipe_pack_dir "$pack")"
done < <(rtc_list_recipe_packs)

# Comma-separated "Radius.<Category>=<sha>" list for the source rewrite.
sha_map="$(awk -F'\t' '{ printf "%s%s=%s", (NR > 1 ? "," : ""), $1, $2 }' <<<"$namespace_pins")"

# Rewrite repo-owned Recipe sources in one pack template to the commit SHA
# their Resource Type's namespace is pinned to. Relies on the entry shape that
# lib-recipe-packs.sh documents: a `'Radius.<Category>/<type>': {` key line
# followed by that entry's own `source:` line.
pin_pack_sources() {
    local template="$1" rewritten="$1.rc"
    awk -v pins="$sha_map" -v prefix="$REPO_RECIPE_SOURCE_PREFIX" -v file="$template" '
        BEGIN {
            n = split(pins, list, ",")
            for (i = 1; i <= n; i++) {
                split(list[i], kv, "=")
                sha[kv[1]] = kv[2]
            }
        }
        /^[[:space:]]*'"'"'Radius\.[A-Za-z0-9]+\/[A-Za-z0-9]+'"'"':[[:space:]]*\{/ {
            match($0, /Radius\.[A-Za-z0-9]+\/[A-Za-z0-9]+/)
            current = substr($0, RSTART, RLENGTH)
            print
            next
        }
        current != "" && /^[[:space:]]*source:[[:space:]]*'"'"'/ {
            if (match($0, /'"'"'[^'"'"']+'"'"'/)) {
                reference = substr($0, RSTART + 1, RLENGTH - 2)
                if (index(reference, prefix) == 1 && reference !~ /@/ && reference ~ /:[A-Za-z0-9._-]+$/) {
                    namespace = current
                    sub(/\/.*/, "", namespace)
                    if (!(namespace in sha)) {
                        printf "Error: %s in %s uses %s, but namespace %s is not pinned\n", current, file, reference, namespace > "/dev/stderr"
                        failed = 1
                    } else {
                        repository = reference
                        sub(/:[^:]*$/, "", repository)
                        $0 = substr($0, 1, RSTART) repository ":" sha[namespace] substr($0, RSTART + RLENGTH - 1)
                        printf "    %s: %s -> %s:%s\n", current, reference, repository, sha[namespace] > "/dev/stderr"
                    }
                }
            }
            current = ""
        }
        { print }
        END { exit failed ? 1 : 0 }
    ' "$template" >"$rewritten" || {
        rm -f "$rewritten"
        return 1
    }
    mv "$rewritten" "$template"
}

while IFS=$'\t' read -r name ref; do
    pack_dir="$(rtc_recipe_pack_dir "$name")"
    echo "==> Recipe Pack $name -> $pack_dir/ @ $ref" >&2
    restore_path "$pack_dir" "$ref"
    templates=()
    while IFS= read -r -d '' template; do
        templates+=("$template")
    done < <(find "$RTC_REPO_ROOT/$pack_dir" -mindepth 1 -maxdepth 1 -type f -name '*.bicep' -print0 | sort -z)
    if [[ ${#templates[@]} -eq 0 ]]; then
        echo "Error: pinned Recipe Pack '$name' has no Bicep template at $ref" >&2
        exit 1
    fi
    for template in "${templates[@]}"; do
        pin_pack_sources "$template"
    done
done <<<"$pack_pins"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'radius_version=%s\nradius_tag=%s\n' "$version" "$radius_tag" >>"$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## Released content pinned by Radius \`${radius_tag}\`"
        echo ""
        echo "| Kind | Name | Commit |"
        echo "| --- | --- | --- |"
        while IFS=$'\t' read -r name ref; do
            echo "| Namespace | \`$name\` | \`$ref\` |"
        done <<<"$namespace_pins"
        while IFS=$'\t' read -r name ref; do
            echo "| Recipe Pack | \`$name\` | \`$ref\` |"
        done <<<"$pack_pins"
    } >>"$GITHUB_STEP_SUMMARY"
fi

echo "==> Prepared released sources for Radius ${radius_tag}" >&2
