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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-recipe-namespace-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repo"
RECIPE_PATH="$FIXTURE_ROOT/Data/widgets/recipes/kubernetes/bicep"
mkdir -p "$RECIPE_PATH" "$FIXTURE_ROOT/Data/widgets/test" "$TEST_ROOT/bin"
touch "$RECIPE_PATH/main.bicep" "$FIXTURE_ROOT/Data/widgets/test/app.bicep"

export COMMAND_CALLS="$TEST_ROOT/command-calls"
: >"$COMMAND_CALLS"
cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
printf 'rad %s\n' "$*" >>"$COMMAND_CALLS"
if [[ "$1 $2" == "env show" ]]; then
    cat <<'JSON'
{"id":"/planes/radius/local/resourcegroups/default/providers/Radius.Core/environments/default","properties":{"providers":{"kubernetes":{"namespace":"radius-preview"}}}}
JSON
fi
EOF
cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
printf 'kubectl %s\n' "$*" >>"$COMMAND_CALLS"
EOF
chmod +x "$TEST_ROOT/bin/rad" "$TEST_ROOT/bin/kubectl"

(
    cd "$FIXTURE_ROOT"
    PATH="$TEST_ROOT/bin:$PATH" "$REPO_ROOT/.github/scripts/test-recipe.sh" "$RECIPE_PATH" >/dev/null
)

if grep -q '^rad env update ' "$COMMAND_CALLS"; then
    echo "Recipe test attempted to update the immutable environment namespace" >&2
    exit 1
fi

for resource in secrets deployments services; do
    grep -qx "kubectl delete $resource --all -n radius-preview" "$COMMAND_CALLS"
done

echo "Recipe namespace test passed"
