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

template="${1:-recipe-packs/azure/aks-recipepack.bicep}"
namespace=azure-aks-pack-validation
environment=azure-aks-pack-validation

: "${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID must be set}"
: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP must be set}"

if [[ ! -f "$template" ]]; then
    echo "Error: Azure Recipe Pack not found: $template" >&2
    exit 1
fi

kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
rad env create "$environment" \
    --azure-subscription-id "$AZURE_SUBSCRIPTION_ID" \
    --azure-resource-group "$AZURE_RESOURCE_GROUP" \
    --kubernetes-namespace "$namespace" \
    --preview

deploy_args=(
    "$template"
    --group default
    --environment "$environment"
    --parameters routesGatewayName=validation-gateway
    --parameters containerImagesRegistry=localhost:5000
)

if grep -Eq '^[[:space:]]*param[[:space:]]+environmentName([[:space:]]|$)' "$template"; then
    deploy_args+=(--parameters "environmentName=$environment")
fi
if grep -Eq '^[[:space:]]*param[[:space:]]+environmentNamespace([[:space:]]|$)' "$template"; then
    deploy_args+=(--parameters "environmentNamespace=$namespace")
fi
if grep -Eq '^[[:space:]]*param[[:space:]]+azureSubscriptionId([[:space:]]|$)' "$template"; then
    deploy_args+=(--parameters "azureSubscriptionId=$AZURE_SUBSCRIPTION_ID")
fi
if grep -Eq '^[[:space:]]*param[[:space:]]+azureResourceGroup([[:space:]]|$)' "$template"; then
    deploy_args+=(--parameters "azureResourceGroup=$AZURE_RESOURCE_GROUP")
fi

rad deploy "${deploy_args[@]}"
rad env update "$environment" --recipe-packs azure-avm --preview
