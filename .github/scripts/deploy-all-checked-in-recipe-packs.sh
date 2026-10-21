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

set -euo pipefail

# Deploys every checked-in Recipe Pack (recipe-packs/**) that targets a given
# platform group, one after another, and associates each with the
# Environment in turn. `--recipe-packs` replaces the Environment's pack list,
# so packs that cover the same Resource Types (e.g. azure-aks and azure-aci)
# can be validated one after the other without interfering with each other.
#
# This is the "Layer 1" check from issue #312: it proves every committed pack
# at least deploys and activates. It says nothing about whether an
# individual Resource Type mapping inside a pack is correct -- see
# validate-direct-module-mappings.sh and test-all-recipe-pack-entries.sh for
# those checks.
#
# New pack added under an existing platform group? Nothing to do here -- it
# is picked up automatically. New platform group? Add a CI job that calls
# this script with that group name, and a case arm in
# rtc_recipe_pack_platform_group() (lib-recipe-packs.sh).
#
# Usage: deploy-all-checked-in-recipe-packs.sh <platform-group> [environment] [radius-group]
# RECIPE_PACK_USE_LOCAL_RECIPES=true publishes and uses checkout recipes in
# the test cluster registry, without changing the checked-in pack. GitHub Actions
# defaults to this mode: pull_request_target runs the base workflow with checkout
# scripts, so a new workflow opt-in alone would not test this PR's recipes.
# Set RECIPE_PACK_USE_LOCAL_RECIPES=false explicitly to test published artifacts.
# Outside GitHub Actions, local mode remains opt-in.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-recipe-packs.sh
source "$SCRIPT_DIR/lib-recipe-packs.sh"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <platform-group> [environment] [radius-group]" >&2
    exit 1
fi

platform_group="$1"
environment="${2:-default}"
radius_group="${3:-default}"
use_local_recipes="${RECIPE_PACK_USE_LOCAL_RECIPES:-${GITHUB_ACTIONS:-false}}"

local_pack_dir=""
cleanup() {
    if [[ -n "$local_pack_dir" ]]; then
        rm -rf -- "$local_pack_dir"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pack_list="$(rtc_recipe_packs_for_platform_group "$platform_group")"
packs=()
if [[ -n "$pack_list" ]]; then
    mapfile -t packs <<<"$pack_list"
fi

if [[ ${#packs[@]} -eq 0 ]]; then
    echo "No checked-in recipe packs target platform group '$platform_group'; nothing to deploy."
    exit 0
fi

for pack_id in "${packs[@]}"; do
    template="$(rtc_recipe_pack_template "$pack_id")"
    pack_name="$(rtc_recipe_pack_name "$template")"
    if [[ -z "$pack_name" ]]; then
        echo "Error: could not determine the recipe pack name declared in $template." >&2
        exit 1
    fi

    parameters=()
    required_params="$(rtc_recipe_pack_required_params "$template")"
    while IFS= read -r param_name; do
        [[ -z "$param_name" ]] && continue
        param_value="$(rtc_recipe_pack_param_value "$param_name")"
        parameters+=(--parameters "${param_name}=${param_value}")
    done <<<"$required_params"

    if [[ "$use_local_recipes" == "true" ]]; then
        local_recipes="$(rtc_recipe_pack_local_recipes "$template")"
        # Publish every selected checkout recipe, including Kubernetes references
        # omitted by the Azure-only build in a pull_request_target base workflow.
        while IFS=$'\t' read -r resource_type original_source local_source recipe_file; do
            [[ -z "$resource_type" ]] && continue
            echo "==> Local recipe '$resource_type': '$original_source' -> '$local_source' (plainHttp: true)" >&2
            make -s -C "$RTC_REPO_ROOT" build-bicep-recipe RECIPE_PATH="$recipe_file" >&2
        done <<<"$local_recipes"
        if [[ -z "$local_pack_dir" ]]; then
            local_pack_dir="$(mktemp -d "${TMPDIR:-/tmp}/rtc-recipe-packs-XXXXXX")"
            # A relocated Bicep config must retain remote references while
            # resolving local extensions against the original config directory.
            if [[ -f "$RTC_REPO_ROOT/bicepconfig.json" ]]; then
                jq --arg root "$RTC_REPO_ROOT" '
                    .extensions |= ((. // {}) | with_entries(
                        if (.value | type) == "string" and
                           (.value | test("^[A-Za-z][A-Za-z0-9+.-]*:|^/") | not)
                        then .value = ($root + "/" + .value) else . end
                    ))
                ' "$RTC_REPO_ROOT/bicepconfig.json" >"$local_pack_dir/bicepconfig.json"
            else
                printf '%s\n' '{"extensions":{"radius":"br:biceptypes.azurecr.io/radius:latest"}}' \
                    >"$local_pack_dir/bicepconfig.json"
            fi
        fi
        local_template="$local_pack_dir/$pack_id.bicep"
        rtc_recipe_pack_with_local_recipes "$template" "$local_recipes" >"$local_template"
        template="$local_template"
    fi

    echo "==> Deploying checked-in recipe pack '$pack_id' ($template)"
    rad deploy "$template" \
        --group "$radius_group" \
        --environment "$environment" \
        ${parameters[@]+"${parameters[@]}"}

    echo "==> Activating recipe pack '$pack_name' on environment '$environment'"
    rad env update "$environment" --recipe-packs "$pack_name"
done
