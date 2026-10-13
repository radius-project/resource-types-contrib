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
# validate-direct-module-mappings.sh and test-direct-module-recipe.sh for
# that.
#
# New pack added under an existing platform group? Nothing to do here -- it
# is picked up automatically. New platform group? Add a CI job that calls
# this script with that group name, and a case arm in
# rtc_recipe_pack_platform_group() (lib-recipe-packs.sh).
#
# Usage: deploy-all-checked-in-recipe-packs.sh <platform-group> [environment] [radius-group]

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

    echo "==> Deploying checked-in recipe pack '$pack_id' ($template)"
    rad deploy "$template" \
        --group "$radius_group" \
        --environment "$environment" \
        ${parameters[@]+"${parameters[@]}"}

    echo "==> Activating recipe pack '$pack_name' on environment '$environment'"
    rad env update "$environment" --recipe-packs "$pack_name" --preview
done
