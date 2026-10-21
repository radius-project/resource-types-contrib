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

SOURCE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AZURE_ACI_PACK="$SOURCE_REPO_ROOT/recipe-packs/azure-aci/azure-aci.bicep"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-recipe-pack-validation-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

run_validator() {
    REPO_ROOT="$TEST_ROOT" "$SOURCE_REPO_ROOT/.github/scripts/validate-recipe-packs.sh" >/dev/null 2>&1
}

write_pack() {
    mkdir -p "$TEST_ROOT/recipe-packs/test"
    cat >"$TEST_ROOT/recipe-packs/test/test-recipepack.bicep"
}

write_pack <<'EOF'
  resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {}
EOF
run_validator

write_pack <<'EOF'
// resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {}
EOF
if run_validator; then
    echo "Comment-only Recipe Pack declaration unexpectedly passed validation" >&2
    exit 1
fi

write_pack <<'EOF'
resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {}
module environment './environment.bicep' = {}
EOF
if run_validator; then
    echo "Recipe Pack containing a module unexpectedly passed validation" >&2
    exit 1
fi

write_pack <<'EOF'
resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {}
resource environment 'Radius.Core/environments@2025-08-01-preview' = {}
EOF
if run_validator; then
    echo "Recipe Pack containing an Environment unexpectedly passed validation" >&2
    exit 1
fi

expected_source="source: 'ghcr.io/radius-project/azure-aci-recipes/containers@sha256:4295fac3aded4a823e0de8394c5996833fedd35206614497ec3caa32b8cbc278'"
grep -Fq "$expected_source" "$AZURE_ACI_PACK" || {
    echo "Azure ACI containers must use the verified artifact that returns hosts" >&2
    exit 1
}
if grep -Fq "source: 'ghcr.io/radius-project/azure-aci-recipes/containers:latest'" "$AZURE_ACI_PACK"; then
    echo "Azure ACI containers must not use the floating latest tag" >&2
    exit 1
fi

echo "Recipe Pack validator tests passed"
