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

# pull_request_target uses the base workflow with scripts from the PR checkout.
# Keep its old entry point until all callers use the shared deployment driver.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-recipe-packs.sh"

template="${1:-recipe-packs/azure-aks/azure-aks.bicep}"
pack_name="${2:-azure-aks}"
if [[ ! -f "$template" ]]; then
    echo "Error: Azure Recipe Pack not found: $template" >&2
    exit 1
fi

required_params="$(rtc_recipe_pack_required_params "$template")"
parameters=()
while IFS= read -r param_name; do
    [[ -z "$param_name" ]] && continue
    param_value="$(rtc_recipe_pack_param_value "$param_name")"
    parameters+=(--parameters "${param_name}=${param_value}")
done <<<"$required_params"

rad deploy "$template" --group default --environment default "${parameters[@]}"
rad env update default --recipe-packs "$pack_name" --preview
