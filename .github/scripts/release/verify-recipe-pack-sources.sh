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
# verify-recipe-pack-sources.sh
# -----------------------------------------------------------------------------
# Fail a recipe pack release when any OCI Recipe source the pack references
# cannot be pulled anonymously. Registering a pack only records the source
# strings; Radius pulls them when a resource is deployed. Without this check a
# pack could be released while a referenced tag (for example a new registry's
# `latest`, which only a stable `release_version` publish creates) does not
# exist yet, or while its GHCR package is still private.
#
# Only literal `source: '<registry>/<repository>:<tag>'` (or `@<digest>`)
# values in the pack's top-level Bicep templates are checked; interpolated
# values and non-OCI strings are skipped.
#
# Inputs (environment variables):
#   RECIPE_PACK         required, e.g. azure-aci
#   REPO_ROOT           repository root (default: git toplevel, else CWD)
#   CHECK_SOURCE_CMD    optional command run as `$CHECK_SOURCE_CMD <reference>`
#                       instead of the built-in anonymous registry check
#                       (used by tests)
#
# Usage:
#   RECIPE_PACK=azure-aci ./.github/scripts/release/verify-recipe-pack-sources.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/release/lib.sh
source "$SCRIPT_DIR/lib.sh"

RECIPE_PACK="${RECIPE_PACK:-}"
CHECK_SOURCE_CMD="${CHECK_SOURCE_CMD:-}"

if [[ -z "$RECIPE_PACK" ]]; then
    echo "Error: RECIPE_PACK is required" >&2
    exit 1
fi

if ! rtc_is_recipe_pack "$RECIPE_PACK"; then
    echo "Error: '$RECIPE_PACK' is not a releasable recipe pack" >&2
    exit 1
fi

PACK_DIR_ABS="$RTC_REPO_ROOT/$(rtc_recipe_pack_dir "$RECIPE_PACK")"

readonly OCI_REFERENCE='^[a-z0-9.-]+\.[a-z]+(:[0-9]+)?/[a-z0-9._/-]+(:[A-Za-z0-9._-]+|@sha256:[a-f0-9]{64})$'
readonly MANIFEST_ACCEPT='application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json'

# Anonymously resolve <registry>/<repository>:<tag|@digest> through the OCI
# distribution API, following a Bearer token challenge when the registry
# requires one.
check_source() {
    local reference="$1" registry path repository tag url status challenge realm service token
    registry="${reference%%/*}"
    path="${reference#*/}"
    if [[ "$path" == *@* ]]; then
        repository="${path%@*}"
        tag="${path#*@}"
    else
        repository="${path%:*}"
        tag="${path##*:}"
    fi
    url="https://${registry}/v2/${repository}/manifests/${tag}"

    status="$(curl -sS -o /dev/null -w '%{http_code}' -I -H "Accept: ${MANIFEST_ACCEPT}" "$url" || echo 000)"
    if [[ "$status" == "401" ]]; then
        challenge="$(curl -sS -I -H "Accept: ${MANIFEST_ACCEPT}" "$url" | tr -d '\r' | grep -i '^www-authenticate: bearer ' || true)"
        realm="$(sed -nE 's/.*realm="([^"]+)".*/\1/p' <<<"$challenge")"
        service="$(sed -nE 's/.*service="([^"]+)".*/\1/p' <<<"$challenge")"
        [[ -n "$realm" ]] || return 1
        token="$(curl -sS -G "$realm" --data-urlencode "service=${service}" \
            --data-urlencode "scope=repository:${repository}:pull" |
            sed -nE 's/.*"(token|access_token)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p')"
        [[ -n "$token" ]] || return 1
        status="$(curl -sS -o /dev/null -w '%{http_code}' -I -H "Accept: ${MANIFEST_ACCEPT}" \
            -H "Authorization: Bearer ${token}" "$url" || echo 000)"
    fi
    [[ "$status" == "200" ]]
}

sources=()
while IFS= read -r source; do
    sources+=("$source")
done < <(
    find "$PACK_DIR_ABS" -mindepth 1 -maxdepth 1 -type f -name '*.bicep' -print0 |
        xargs -0 sed -nE "s/^[[:space:]]*source:[[:space:]]*'([^']+)'.*/\1/p" |
        { grep -E "$OCI_REFERENCE" || true; } | sort -u
)

if [[ "${#sources[@]}" -eq 0 ]]; then
    echo "Error: no OCI Recipe sources found under '$PACK_DIR_ABS'" >&2
    exit 1
fi

missing=()
for source in "${sources[@]}"; do
    if [[ -n "$CHECK_SOURCE_CMD" ]]; then
        if $CHECK_SOURCE_CMD "$source"; then ok=true; else ok=false; fi
    elif check_source "$source"; then
        ok=true
    else
        ok=false
    fi
    if [[ "$ok" == "true" ]]; then
        echo "ok       $source" >&2
    else
        echo "MISSING  $source" >&2
        missing+=("$source")
    fi
done

if [[ "${#missing[@]}" -gt 0 ]]; then
    {
        echo "Error: ${#missing[@]} Recipe source(s) in the '$RECIPE_PACK' pack cannot be pulled anonymously."
        echo "Publish them (for a new registry's 'latest', dispatch Publish Bicep Recipes with a stable"
        echo "release_version) and make sure the GHCR packages are public before releasing this pack."
    } >&2
    exit 1
fi

echo "All ${#sources[@]} Recipe sources in the '$RECIPE_PACK' pack resolve." >&2
