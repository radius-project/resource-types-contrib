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
VALIDATOR="$REPO_ROOT/.github/scripts/validate-svg-icons.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-svg-icon-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/valid" "$TEST_ROOT/style-element" "$TEST_ROOT/style-attribute"
printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg"><path fill="black"/></svg>' >"$TEST_ROOT/valid/icon.svg"
printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg"><STYLE' '>.icon { fill: black; }</STYLE></svg>' >"$TEST_ROOT/style-element/icon.svg"
printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg"><path STYLE' '= "fill: black"/></svg>' >"$TEST_ROOT/style-attribute/icon.svg"

"$VALIDATOR" "$TEST_ROOT/valid" >/dev/null

if "$VALIDATOR" "$TEST_ROOT/style-element" >/dev/null 2>&1; then
    echo "Validator accepted an SVG style element" >&2
    exit 1
fi

if "$VALIDATOR" "$TEST_ROOT/style-attribute" >/dev/null 2>&1; then
    echo "Validator accepted an SVG style attribute" >&2
    exit 1
fi

"$VALIDATOR" "$REPO_ROOT"
echo "SVG icon tests passed"
