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

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PACK_ROOT="$REPO_ROOT/recipe-packs"
pack_count=0

while IFS= read -r pack; do
    pack_count=$((pack_count + 1))

    if ! grep -Eq "^[[:space:]]*resource[[:space:]]+[[:alnum:]_]+[[:space:]]+'Radius\\.Core/recipePacks@[^']+'[[:space:]]*=" "$pack"; then
        echo "Error: Recipe Pack does not declare a Radius.Core/recipePacks resource: ${pack#"$REPO_ROOT/"}" >&2
        exit 1
    fi

    unexpected_declarations="$(
        {
            grep -En "^[[:space:]]*resource[[:space:]]+[[:alnum:]_]+[[:space:]]+'" "$pack" |
                grep -Ev "^[0-9]+:[[:space:]]*resource[[:space:]]+[[:alnum:]_]+[[:space:]]+'Radius\\.Core/recipePacks@[^']+'[[:space:]]*=" || true
            grep -En "^[[:space:]]*module[[:space:]]+[[:alnum:]_]+[[:space:]]+" "$pack" || true
        }
    )"
    if [[ -n "$unexpected_declarations" ]]; then
        echo "Error: Recipe Pack declares resources or modules other than Radius.Core/recipePacks: ${pack#"$REPO_ROOT/"}" >&2
        echo "$unexpected_declarations" >&2
        exit 1
    fi
done < <(find "$PACK_ROOT" -type f -name '*.bicep' | sort)

if [[ "$pack_count" -eq 0 ]]; then
    echo "Error: no checked-in Recipe Pack Bicep files found under recipe-packs/" >&2
    exit 1
fi

echo "Validated $pack_count checked-in Recipe Pack Bicep file(s)"
