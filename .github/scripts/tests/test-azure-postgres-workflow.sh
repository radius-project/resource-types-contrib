#!/bin/bash
# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="$root/.github/scripts/azure-postgres-workflow.sh"
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
unset RTC_AZURE_TEST_REGIONS AZURE_LOCATION AZURE_FALLBACK_LOCATION
[[ "$(bash "$script" regions)" == westus3,eastus2,centralus,westus2 ]] || fail defaults
[[ "$(AZURE_LOCATION=eastus AZURE_FALLBACK_LOCATION=northeurope bash "$script" regions)" == \
    eastus,northeurope,centralus,westus2 ]] || fail "legacy settings"
[[ "$(AZURE_LOCATION=centralus AZURE_FALLBACK_LOCATION=centralus bash "$script" regions)" == \
    centralus,westus2 ]] || fail "stable deduplication"
[[ "$(RTC_AZURE_TEST_REGIONS=westus2,westus2,eastus2 AZURE_LOCATION=bad bash "$script" regions)" == \
    westus2,eastus2 ]] || fail "override precedence"
[[ "$(RTC_AZURE_TEST_REGIONS=centralus bash "$script" regions)" == centralus ]] || fail "single region"
for list in '' Westus3 'eastus2,' 'eastus2,,centralus' 'a,b,c,d,e' $'eastus2\r' $'eastus2\nwestus2'; do
    if RTC_AZURE_TEST_REGIONS="$list" bash "$script" regions >/dev/null 2>&1; then fail "invalid list"; fi
done
if RTC_AZURE_TEST_REGIONS="$(printf 'eastus2,%.0s' {1..32})eastus2" \
    bash "$script" regions >/dev/null 2>&1; then fail "raw list bound"; fi

export RTC_AZURE_SELECTION_FILE="$temp/selection.json" GITHUB_STEP_SUMMARY="$temp/summary.md"
for status in selected capacity_exhausted probe_error deadline_exceeded; do
    jq -n --arg status "$status" '{version:1,status:$status,deadlineEpochSeconds:123456,
        secret:"DO_NOT_PRINT",attempts:[{region:"centralus",size:"M",skuName:"Standard_D2ds_v5",
        tier:"GeneralPurpose",outcome:"capacity_exhausted",errorCode:"SkuNotAvailable",durationSeconds:12}]}' \
        >"$RTC_AZURE_SELECTION_FILE"
    : >"$GITHUB_STEP_SUMMARY"
    bash "$script" summary
    grep -Fq "Final selection status: **$status**" "$GITHUB_STEP_SUMMARY" || fail "status summary"
    grep -Fq '| centralus | M | Standard_D2ds_v5 | GeneralPurpose | capacity_exhausted | SkuNotAvailable | 12 |' \
        "$GITHUB_STEP_SUMMARY" || fail "attempt table"
    ! grep -q DO_NOT_PRINT "$GITHUB_STEP_SUMMARY" || fail "unexpected fields leaked"
done
printf '%s\n' '{}' >"$RTC_AZURE_SELECTION_FILE"
if bash "$script" summary 2>/dev/null; then fail "malformed summary"; fi
rm "$RTC_AZURE_SELECTION_FILE"
if bash "$script" summary 2>/dev/null; then fail "missing summary"; fi

mkdir "$temp/bin"
export CALL_LOG="$temp/calls" GROUP_STATE="$temp/state"
cat >"$temp/bin/az" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "$*" >>"$CALL_LOG"
case "$2" in
    exists) cat "$GROUP_STATE" ;;
    delete)
        if [[ "${DELETE_FAILS:-}" == true ]]; then exit 1; fi
        if [[ "${DELETE_STUCK:-}" != true ]]; then echo false >"$GROUP_STATE"; fi ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$temp/bin/az"
export PATH="$temp/bin:$PATH" GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=2 AZURE_SUBSCRIPTION_ID=test
for kind in nightly rc; do
    echo true >"$GROUP_STATE"
    : >"$CALL_LOG"
    bash "$script" cleanup-probe "rrttest-$kind-123-2-probe"
    grep -q "group delete --name rrttest-$kind-123-2-probe --subscription test" "$CALL_LOG" ||
        fail "exact owned group"
    ! grep -q -- --no-wait "$CALL_LOG" || fail "must confirm deletion"
    : >"$CALL_LOG"
    bash "$script" cleanup-probe "rrttest-$kind-123-2-probe"
    ! grep -q 'group delete' "$CALL_LOG" || fail "missing group is idempotent"
done
: >"$CALL_LOG"
bash "$script" cleanup-probe ''
for group in caller-owned rrttest-nightly-124-2-probe rrttest-rc-123-1-probe; do
    if bash "$script" cleanup-probe "$group" 2>/dev/null; then fail "ownership guard"; fi
done
[[ ! -s "$CALL_LOG" ]] || fail "must reject before Azure calls"
echo true >"$GROUP_STATE"
if DELETE_FAILS=true bash "$script" cleanup-probe rrttest-nightly-123-2-probe 2>/dev/null; then
    fail "delete error"
fi
if DELETE_STUCK=true bash "$script" cleanup-probe rrttest-nightly-123-2-probe 2>/dev/null; then
    fail "delete must be confirmed"
fi
echo "Azure PostgreSQL workflow tests passed"
