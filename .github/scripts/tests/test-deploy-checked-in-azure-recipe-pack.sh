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
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-azure-pack-lifecycle-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin"

cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "rad $*" >>"$CALL_LOG"
EOF

chmod +x "$TEST_ROOT/bin/rad"

run_case() {
    local name="$1"
    local template="$TEST_ROOT/$name.bicep"
    local actual="$TEST_ROOT/$name.calls"

    cat >"$template"
    : >"$actual"

    PATH="$TEST_ROOT/bin:$PATH" \
        CALL_LOG="$actual" \
        "$REPO_ROOT/.github/scripts/deploy-checked-in-azure-recipe-pack.sh" "$template"
}

run_case pack-only <<'EOF'
param routesGatewayName string
param containerImagesRegistry string
resource recipes 'Radius.Core/recipePacks@2025-08-01-preview' = {}
EOF
cat >"$TEST_ROOT/pack-only.expected" <<EOF
rad deploy $TEST_ROOT/pack-only.bicep --group default --environment default --parameters routesGatewayName=validation-gateway --parameters containerImagesRegistry=localhost:5000
rad env update default --recipe-packs azure-avm --preview
EOF
diff -u "$TEST_ROOT/pack-only.expected" "$TEST_ROOT/pack-only.calls"

echo "Checked-in Azure Recipe Pack lifecycle tests passed"
