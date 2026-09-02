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

ROOT="${1:-.}"
PATTERN='<style([[:space:]>]|$)|[[:space:]]style([[:space:]]*=|[[:space:]]*$)'

svg_files=()
while IFS= read -r -d '' file; do
    svg_files+=("$file")
done < <(find "$ROOT" -type f -name '*.svg' -print0)
if ((${#svg_files[@]} == 0)); then
    echo "No SVG files found under $ROOT" >&2
    exit 1
fi

if grep -Ein "$PATTERN" "${svg_files[@]}"; then
    echo "SVG files must not contain <style> elements or style attributes" >&2
    exit 1
fi

echo "SVG icon validation passed"
