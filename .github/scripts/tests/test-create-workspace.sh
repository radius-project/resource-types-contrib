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
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-workspace-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export COMMAND_CALLS="$TEST_ROOT/command-calls"
mkdir -p "$TEST_ROOT/bin"
: >"$COMMAND_CALLS"
cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
printf 'rad %s\n' "$*" >>"$COMMAND_CALLS"
EOF
cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
printf 'kubectl %s\n' "$*" >>"$COMMAND_CALLS"
EOF
chmod +x "$TEST_ROOT/bin/rad" "$TEST_ROOT/bin/kubectl"

PATH="$TEST_ROOT/bin:$PATH" "$REPO_ROOT/.github/scripts/create-workspace.sh" >/dev/null

cat >"$TEST_ROOT/expected" <<'EOF'
kubectl create namespace radius-recipe-validation
rad group create default
rad workspace create kubernetes default --group default --force
rad group switch default
rad env create default --kubernetes-namespace radius-recipe-validation --preview
rad env switch default --preview
EOF

diff -u "$TEST_ROOT/expected" "$COMMAND_CALLS"
echo "Workspace bootstrap test passed"
