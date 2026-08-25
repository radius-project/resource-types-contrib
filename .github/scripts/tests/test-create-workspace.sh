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

export RAD_CALLS="$TEST_ROOT/rad-calls"
mkdir -p "$TEST_ROOT/bin"
: >"$RAD_CALLS"
cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$RAD_CALLS"
EOF
chmod +x "$TEST_ROOT/bin/rad"

PATH="$TEST_ROOT/bin:$PATH" "$REPO_ROOT/.github/scripts/create-workspace.sh" >/dev/null

cat >"$TEST_ROOT/expected" <<'EOF'
group create default
workspace create kubernetes default --group default --force
group switch default
env create default --kubernetes-namespace radius-preview --preview
env switch default --preview
EOF

diff -u "$TEST_ROOT/expected" "$RAD_CALLS"
echo "Workspace bootstrap test passed"
