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
# shellcheck source=.github/scripts/lib-azure-postgres-test.sh
source "$REPO_ROOT/.github/scripts/lib-azure-postgres-test.sh"
pack="${RTC_POSTGRES_POLICY_PACK_FILE:-$REPO_ROOT/recipe-packs/azure-aks/azure-aks.bicep}"
entry="$(sed -n "/'Radius.Data\/postgreSqlDatabases': {/,/'Radius.Data\/sqlServerDatabases': {/p" "$pack")"
fail() { echo "FAIL: Azure PostgreSQL test policy differs from $pack: $1" >&2; exit 1; }
rtc_postgres_test_tuple S
small_sku="$postgres_sku"; small_tier="$postgres_tier"
rtc_postgres_test_tuple M
grep -Fq "skuName: '{{context.resource.properties.size == \"S\" ? \"$small_sku\" : \"$postgres_sku\"}}'" <<<"$entry" ||
    fail "SKU mapping"
grep -Fq "tier: '{{context.resource.properties.size == \"S\" ? \"$small_tier\" : \"$postgres_tier\"}}'" <<<"$entry" ||
    fail "tier mapping"
for setting in "version: '16'" "availabilityZone: -1" "highAvailability: 'Disabled'" \
    "geoRedundantBackup: 'Disabled'" "storageSizeGB: 32" "publicNetworkAccess: 'Enabled'" \
    "activeDirectoryAuth: 'Enabled'" "passwordAuth: 'Enabled'"; do
    grep -Fq "$setting" <<<"$entry" || fail "$setting"
done
# Check that the guard rejects a changed production mapping, not just this pack.
if [[ -z "${RTC_POSTGRES_POLICY_PACK_FILE:-}" ]]; then
    test_pack="$(mktemp "${TMPDIR:-/tmp}/rtc-postgres-policy-XXXXXX")"
    trap 'rm -f -- "$test_pack"' EXIT
    sed 's/Standard_B1ms/Standard_B2ms/g' "$pack" >"$test_pack"
    if RTC_POSTGRES_POLICY_PACK_FILE="$test_pack" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
        fail "SKU drift was not detected"
    fi
    sed 's/GeneralPurpose/MemoryOptimized/g' "$pack" >"$test_pack"
    if RTC_POSTGRES_POLICY_PACK_FILE="$test_pack" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
        fail "tier drift was not detected"
    fi
fi
echo "Azure PostgreSQL test policy matches the pack"
