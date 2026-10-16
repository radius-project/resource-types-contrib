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

# Unit tests for validate-direct-module-mappings.sh. Builds a small fixture
# repo with one pack and four direct-module Resource Types covering each
# outcome the script needs to get right, with no dependency on real repo
# content:
#   Data/gadgets   - two enum values share an else branch -> OK
#   Data/widgets   - enum property interpolated directly, no comparison
#                    at all -> OK (nothing to check, not an error)
#   Data/sprockets - comparison with an undeclared enum value -> ERROR
#   Data/doodads   - references a property that doesn't exist -> ERROR

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-validate-mappings-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repo"

write_schema() {
    local dir="$1" type_name="$2" extra_properties="$3"
    mkdir -p "$FIXTURE_ROOT/$dir/test"
    touch "$FIXTURE_ROOT/$dir/test/app.bicep"
    cat >"$FIXTURE_ROOT/$dir/$type_name.yaml" <<EOF
namespace: Radius.Test
types:
  $type_name:
    description: Fixture type for validate-direct-module-mappings.sh tests.
    apiVersions:
      '2025-08-01-preview':
        schema:
          type: object
          properties:
            environment:
              type: string
              description: (Required) env.
$extra_properties
          required:
            - environment
EOF
}

write_schema "Data/gadgets" "gadgets" "            color:
              type: string
              enum: ['red', 'green', 'blue']
              description: (Optional) color."

write_schema "Data/widgets" "widgets" "            shape:
              type: string
              enum: ['round', 'square']
              description: (Optional) shape."

write_schema "Data/sprockets" "sprockets" "            tier:
              type: string
              enum: ['low', 'mid', 'high']
              description: (Optional) tier."

write_schema "Data/doodads" "doodads" "            label:
              type: string
              description: (Optional) label."

mkdir -p "$FIXTURE_ROOT/recipe-packs/azure-aks"
cat >"$FIXTURE_ROOT/recipe-packs/azure-aks/azure-aks.bicep" <<'EOF'
resource azureAksRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'azure-aks'
  properties: {
    recipes: {
      'Radius.Data/gadgets': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/some/gadget-module:1.0.0'
        parameters: {
          colorValue: '{{context.resource.properties.color == "red" ? "R" : "GB"}}'
        }
      }
      'Radius.Data/widgets': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/some/widget-module:1.0.0'
        parameters: {
          shapeValue: '{{context.resource.properties.shape}}'
        }
      }
      'Radius.Data/sprockets': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/some/sprocket-module:1.0.0'
        parameters: {
          tierValue: '{{context.resource.properties.tier == "ultra" ? "L" : "H"}}'
        }
      }
      'Radius.Data/doodads': {
        kind: 'bicep'
        source: 'mcr.microsoft.com/bicep/avm/res/some/doodad-module:1.0.0'
        parameters: {
          labelValue: '{{context.resource.properties.lable}}'
        }
      }
    }
  }
}
EOF

export RTC_REPO_ROOT="$FIXTURE_ROOT"
cd "$FIXTURE_ROOT"

set +e
output="$("$REPO_ROOT/.github/scripts/validate-direct-module-mappings.sh" 2>&1)"
exit_code=$?
set -e

fail() {
    echo "FAIL: $1" >&2
    echo "--- script output ---" >&2
    echo "$output" >&2
    exit 1
}

[[ "$exit_code" -ne 0 ]] || fail "script should have exited non-zero (sprockets/doodads are real errors)"

echo "$output" | grep -q "Data/sprockets.*'tier' compares undeclared enum value 'ultra'" ||
    fail "expected an invalid enum comparison error for Data/sprockets 'tier'"

echo "$output" | grep -q "Data/doodads.*references undeclared property 'lable'" ||
    fail "expected an undeclared-property error for Data/doodads 'lable'"

echo "$output" | grep -q "Data/gadgets" &&
    fail "Data/gadgets is fully handled and should not have been flagged"

echo "$output" | grep -q "Data/widgets" &&
    fail "Data/widgets has no comparison at all and should not have been flagged"

echo "validate-direct-module-mappings.sh test passed"
