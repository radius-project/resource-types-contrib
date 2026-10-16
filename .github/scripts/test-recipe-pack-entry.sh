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
# Deploys one Resource Type's test/app.bicep against an environment whose
# active checked-in Recipe Pack contains the Resource Type.
#
# The script does not register or unregister an individual recipe. The active
# pack must resolve the Resource Type.
#
# Usage: ./test-recipe-pack-entry.sh <resource-type-dir> <workspace-name> <environment-name>
# Example: ./test-recipe-pack-entry.sh Data/mySqlDatabases default default
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

RESOURCE_TYPE_PATH="$(realpath --relative-to="$(pwd)" "$RESOURCE_TYPE_PATH" 2>/dev/null || echo "$RESOURCE_TYPE_PATH")"
RESOURCE_TYPE_PATH="${RESOURCE_TYPE_PATH#./}"

TEST_FILE="$RESOURCE_TYPE_PATH/test/app.bicep"
if [[ ! -f "$TEST_FILE" ]]; then
    echo "==> No test file found at $TEST_FILE, skipping deployment test"
    exit 0
fi

CATEGORY=$(basename "$(dirname "$RESOURCE_TYPE_PATH")")
RESOURCE_NAME=$(basename "$RESOURCE_TYPE_PATH")
RESOURCE_TYPE="Radius.$CATEGORY/$RESOURCE_NAME"

echo "==> Testing Recipe Pack entry for $RESOURCE_TYPE"
echo "==> Workspace: $WORKSPACE_NAME"
echo "==> Environment: $ENVIRONMENT_NAME"

rtc_ensure_workspace_context "$WORKSPACE_NAME"
if ! RESOLVED=$(rtc_resolve_environment_path "$ENVIRONMENT_NAME" "$WORKSPACE_NAME"); then
    exit 1
fi
IFS=$'\t' read -r ENVIRONMENT_PATH KUBERNETES_NAMESPACE <<<"$RESOLVED"
echo "==> Environment path: $ENVIRONMENT_PATH"

if [[ "$RESOURCE_TYPE" == "Radius.Data/mySqlDatabases" ]]; then
    for tls in required optional; do
        echo "==> Testing MySQL transport policy: $tls"
        rtc_deploy_and_assert_test_app "$TEST_FILE" "$RESOURCE_TYPE" "recipepacktest-$tls" \
            "$ENVIRONMENT_PATH" "$WORKSPACE_NAME" "$KUBERNETES_NAMESPACE" \
            --parameters "tls=$tls" --parameters "@$RESOURCE_TYPE_PATH/test/verify-transport.parameters.json" || exit 1
    done
else
    rtc_deploy_and_assert_test_app "$TEST_FILE" "$RESOURCE_TYPE" "recipepacktest" \
        "$ENVIRONMENT_PATH" "$WORKSPACE_NAME" "$KUBERNETES_NAMESPACE" || exit 1
fi
echo "==> Test completed successfully"
