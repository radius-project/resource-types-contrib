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
# Publish one Bicep recipe once per source commit and tag the same digest.
# Called once per recipe by the publish-bicep-recipes workflow, which
# runs the invocations as parallel steps in a single job.
#
# Arguments:
#   $1  recipe name, used as the registry repository (e.g. containers)
#   $2  path to the Bicep recipe, relative to the repository root
#
# Inputs (environment variables):
#   REGISTRY             required, e.g. ghcr.io/radius-project/kube-recipes
#   TAGS                 required, source SHA followed by edge or a full version
#   RECIPE_SUBJECTS_DIR  optional; when set, records "<sha256>  <repository>"
#                        for every published tag in a new file there, for the
#                        workflow's provenance attestation (requires oras)
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

digest="$(bash "$(dirname "${BASH_SOURCE[0]}")/recipe-oci.sh" publish \
    "$RECIPE_PATH" "$REGISTRY/$NAME" "${tags[0]}" "${tags[@]}")"

if [[ -n "${RECIPE_SUBJECTS_DIR:-}" ]]; then
    # Parallel publish steps share the directory, so each writes its own file.
    subjects="$(mktemp "${RECIPE_SUBJECTS_DIR}/subjects-XXXXXX")"
    printf '%s  %s\n' "${digest#sha256:}" "${REGISTRY}/${NAME}" >"$subjects"
fi
