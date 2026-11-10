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
fail() { echo "FAIL: Azure PostgreSQL test policy differs from $pack: $1" >&2; exit 1; }
rtc_validate_postgres_test_pack "$pack" "${1:-}" || fail "approved tuple or settings"
# Check that the guard rejects a changed production mapping, not just this pack.
if [[ -z "${RTC_POSTGRES_POLICY_PACK_FILE:-}" ]]; then
    test_pack="$(mktemp "${TMPDIR:-/tmp}/rtc-postgres-policy-XXXXXX")"
    trap 'rm -f -- "$test_pack"' EXIT
    source_file="$pack"
    if grep -Fq "azure-aks-recipes/postgresqldatabases:" "$pack"; then
        source_file="$REPO_ROOT/Data/postgreSqlDatabases/recipes/azure/bicep/azure-postgresql.bicep"
    fi
    sed 's/Standard_B1ms/Standard_B2ms/g' "$source_file" >"$test_pack"
    test_args=("$test_pack")
    [[ "$source_file" == "$pack" ]] || test_args=("$pack" "$test_pack")
    if rtc_validate_postgres_test_pack "${test_args[@]}" >/dev/null 2>&1; then
        fail "SKU drift was not detected"
    fi
    sed 's/GeneralPurpose/MemoryOptimized/g' "$source_file" >"$test_pack"
    if rtc_validate_postgres_test_pack "${test_args[@]}" >/dev/null 2>&1; then
        fail "tier drift was not detected"
    fi
    if [[ "$source_file" != "$pack" ]]; then
        sed 's/flexible-server:0.15.2/flexible-server:0.15.1/' "$source_file" >"$test_pack"
        if rtc_validate_postgres_test_pack "${test_args[@]}" >/dev/null 2>&1; then
            fail "AVM version drift was not detected"
        fi
        if rtc_validate_postgres_test_pack "$pack" "$test_pack.missing" >/dev/null 2>&1; then
            fail "missing wrapper was not detected"
        fi
        sed 's/context\.?azure\.?resourceNameHash/context.?azure.?unusedHash/g' "$source_file" >"$test_pack"
        if rtc_validate_postgres_test_pack "$pack" "$test_pack" >/dev/null 2>&1; then
            fail "missing runtime name hash was not detected"
        fi
        sed "/postgreSqlServerConfigurations: postgreSqlServerConfigurations/i\\
          postgreSqlServerName: 'pgsql-{{context.azure.resourceNameHash}}'" "$pack" >"$test_pack"
        if rtc_validate_postgres_test_pack "$test_pack" "$source_file" >/dev/null 2>&1; then
            fail "unresolved pack name override was not detected"
        fi
    fi
fi
echo "Azure PostgreSQL test policy matches the pack"
