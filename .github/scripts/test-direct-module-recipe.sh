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
# Deploys a single direct-module Resource Type's test/app.bicep against an
# environment that already has a checked-in Recipe Pack active on it (from
# deploy-all-checked-in-recipe-packs.sh), and asserts the result.
#
# This is "Layer 3" from issue #312: the real-deployment counterpart to
# validate-direct-module-mappings.sh's static check. It covers the exact
# gap issue #312 describes -- a Resource Type whose only recipe is a
# third-party module reference baked directly into a pack, never exercised
# by any recipes/<platform>/ folder test.
#
# Unlike test-recipe.sh, this script does NOT register or unregister a
# single recipe: the Resource Type must already be resolvable because a pack
# covering it is active on the given environment. The all-types driver
# activates each deployed pack before calling this script.
#
# Usage: ./test-direct-module-recipe.sh <resource-type-dir> <workspace-name> <environment-name>
# Example: ./test-direct-module-recipe.sh Data/mySqlDatabases default default
# =============================================================================

set -euo pipefail

RESOURCE_TYPE_PATH="${1:-}"
WORKSPACE_NAME="${2:-}"
ENVIRONMENT_NAME="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-recipe-test.sh
source "$SCRIPT_DIR/lib-recipe-test.sh"

if [[ -z "$RESOURCE_TYPE_PATH" || -z "$WORKSPACE_NAME" || -z "$ENVIRONMENT_NAME" ]]; then
    echo "Usage: $0 <resource-type-dir> <workspace-name> <environment-name>" >&2
    echo "Example: $0 Data/mySqlDatabases default default" >&2
    exit 1
fi

if [[ ! -d "$RESOURCE_TYPE_PATH" ]]; then
    echo "Error: Resource Type directory not found: $RESOURCE_TYPE_PATH" >&2
    exit 1
fi

# Normalize path: convert absolute to relative for consistency.
RESOURCE_TYPE_PATH="$(realpath --relative-to="$(pwd)" "$RESOURCE_TYPE_PATH" 2>/dev/null || echo "$RESOURCE_TYPE_PATH")"
RESOURCE_TYPE_PATH="${RESOURCE_TYPE_PATH#./}"

TEST_FILE="$RESOURCE_TYPE_PATH/test/app.bicep"
if [[ ! -f "$TEST_FILE" ]]; then
    echo "==> No test file found at $TEST_FILE, skipping deployment test"
    exit 0
fi

# Derive the Resource Type name from its path (e.g. Data/mySqlDatabases ->
# Radius.Data/mySqlDatabases), the same convention used throughout this repo.
CATEGORY=$(basename "$(dirname "$RESOURCE_TYPE_PATH")")
RESOURCE_NAME=$(basename "$RESOURCE_TYPE_PATH")
RESOURCE_TYPE="Radius.$CATEGORY/$RESOURCE_NAME"

echo "==> Testing direct-module mapping for $RESOURCE_TYPE"
echo "==> Workspace: $WORKSPACE_NAME"
echo "==> Environment: $ENVIRONMENT_NAME"

rtc_ensure_workspace_context "$WORKSPACE_NAME"
if ! RESOLVED=$(rtc_resolve_environment_path "$ENVIRONMENT_NAME" "$WORKSPACE_NAME"); then
    exit 1
fi
IFS=$'\t' read -r ENVIRONMENT_PATH KUBERNETES_NAMESPACE <<<"$RESOLVED"
echo "==> Environment path: $ENVIRONMENT_PATH"

if rtc_deploy_and_assert_test_app "$TEST_FILE" "$RESOURCE_TYPE" "directmoduletest" "$ENVIRONMENT_PATH" "$WORKSPACE_NAME" "$KUBERNETES_NAMESPACE"; then
    echo "==> Test completed successfully"
else
    exit 1
fi
