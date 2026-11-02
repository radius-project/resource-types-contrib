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

# Approved test tuples. L is excluded because the pack maps it to the M SKU.
# These variables are return values for callers that source this file.
# shellcheck disable=SC2034
rtc_postgres_test_tuple() {
    case "$1" in
        S) postgres_sku="Standard_B1ms"; postgres_tier="Burstable" ;;
        M) postgres_sku="Standard_D2ds_v5"; postgres_tier="GeneralPurpose" ;;
        *) echo "Error: PostgreSQL test size must be S or M." >&2; return 1 ;;
    esac
}

# Fail closed when a release overlay changes the tuple or required features.
rtc_validate_postgres_test_pack() {
    local pack="$1" entry small_sku small_tier setting
    entry="$(sed -n "/'Radius.Data\/postgreSqlDatabases': {/,/'Radius.Data\/sqlServerDatabases': {/p" "$pack")" || return 1
    rtc_postgres_test_tuple S
    small_sku="$postgres_sku"; small_tier="$postgres_tier"
    rtc_postgres_test_tuple M
    if ! grep -Fq "skuName: '{{context.resource.properties.size == \"S\" ? \"$small_sku\" : \"$postgres_sku\"}}'" <<<"$entry" ||
        ! grep -Fq "tier: '{{context.resource.properties.size == \"S\" ? \"$small_tier\" : \"$postgres_tier\"}}'" <<<"$entry"; then
        echo "Error: PostgreSQL selection policy differs from the pack SKU or tier mapping: $pack" >&2
        return 1
    fi
    for setting in "version: '16'" "availabilityZone: -1" "highAvailability: 'Disabled'" \
        "geoRedundantBackup: 'Disabled'" "storageSizeGB: 32" "publicNetworkAccess: 'Enabled'" \
        "activeDirectoryAuth: 'Enabled'" "passwordAuth: 'Enabled'"; do
        if ! grep -Fq "$setting" <<<"$entry"; then
            echo "Error: PostgreSQL selection policy differs from pack setting $setting: $pack" >&2
            return 1
        fi
    done
}

rtc_postgres_positive_limit() {
    local value="$1" maximum="$2"
    [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]] && ((10#$value <= maximum))
}

# Read Azure CLI codes, not words in an error message. Reject mixed failures.
rtc_postgres_error_codes() {
    python3 - "$1" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as log:
    text = log.read()
decoder = json.JSONDecoder()
codes = set()

def visit(value):
    if isinstance(value, list) and value:
        for item in value:
            visit(item)
    elif isinstance(value, dict):
        code = value.get("code")
        children = [value[key] for key in ("error", "details", "innererror") if key in value]
        if isinstance(code, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", code):
            codes.add(code)
        elif code is not None or not children or "message" in value:
            codes.add("UnknownError")
        for child in children:
            visit(child)
    else:
        codes.add("UnknownError")

while text.strip():
    text = re.sub(r"^(?:error|fatal|failure|failed):\s*", "", text.lstrip(), count=1, flags=re.I)
    if text.startswith(("{", "[")):
        try:
            value, end = decoder.raw_decode(text)
            visit(value)
            text = text[end:]
            continue
        except ValueError:
            pass
    line, _, text = text.partition("\n")
    match = re.fullmatch(r"\(([A-Za-z][A-Za-z0-9]*)\)(?:\s+.*)?", line.strip())
    codes.add(match[1] if match else "UnknownError")

print("\n".join(sorted(codes)))
PY
}
