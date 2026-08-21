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
# Publish one Bicep recipe to a container registry under every tag in
# $TAGS. Called once per recipe by the publish-bicep-recipes workflow, which
# runs the invocations as parallel steps in a single job.
#
# Arguments:
#   $1  recipe name, used as the registry repository (e.g. containers)
#   $2  path to the Bicep recipe, relative to the repository root
#
# Inputs (environment variables):
#   REGISTRY  required, e.g. ghcr.io/radius-project/kube-recipes. The workflow
#             overrides this per step for recipes that target another platform,
#             so the same recipe name can exist under more than one path.
#   TAGS      required, space-separated tags, e.g. "0.51.0 latest"
#
# Usage:
#   ./publish-bicep-recipe.sh containers Compute/containers/recipes/kubernetes/bicep/kubernetes-containers.bicep
# =============================================================================

set -euo pipefail

NAME="${1:?recipe name is required}"
RECIPE_PATH="${2:?recipe path is required}"
: "${REGISTRY:?REGISTRY is required}"
: "${TAGS:?TAGS is required}"

read -ra tags <<<"$TAGS"

for tag in "${tags[@]}"; do
    target="br:${REGISTRY}/${NAME}:${tag}"
    echo "Publishing ${RECIPE_PATH} to ${target}"
    rad bicep publish --file "$RECIPE_PATH" --target "$target"
done
