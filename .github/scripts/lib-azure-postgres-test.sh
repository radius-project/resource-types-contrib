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
    local file="$1"
    if jq -e . "$file" >/dev/null 2>&1; then
        jq -r '.. | objects | .code? // empty |
            if type == "string" and test("^[A-Za-z][A-Za-z0-9]*$") then . else "UnknownError" end' "$file"
    else
        sed -nE 's/^(ERROR: )?\(([A-Za-z][A-Za-z0-9]*)\).*/\2/p' "$file"
    fi
}
