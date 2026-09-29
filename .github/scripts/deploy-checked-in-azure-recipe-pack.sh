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

# Deploys a checked-in Azure Recipe Pack and associates it with the default
# Environment. `--recipe-packs` replaces the Environment's pack list, so packs
# that cover the same Resource Types (azure-aks and azure-aci) can be validated
# one after the other.
#
# Usage: deploy-checked-in-azure-recipe-pack.sh [template] [pack-name]

template="${1:-recipe-packs/azure-aks/azure-aks.bicep}"
pack_name="${2:-azure-aks}"
environment=default

if [[ ! -f "$template" ]]; then
    echo "Error: Azure Recipe Pack not found: $template" >&2
    exit 1
fi

# Only the AKS pack declares these parameters; passing an undeclared parameter
# fails the deployment.
parameters=()
if grep -Eq '^param[[:space:]]+routesGatewayName[[:space:]]' "$template"; then
    parameters+=(--parameters routesGatewayName=validation-gateway)
fi
if grep -Eq '^param[[:space:]]+containerImagesRegistry[[:space:]]' "$template"; then
    parameters+=(--parameters containerImagesRegistry=localhost:5000)
fi

rad deploy "$template" \
    --group default \
    --environment "$environment" \
    ${parameters[@]+"${parameters[@]}"}

rad env update "$environment" --recipe-packs "$pack_name" --preview
