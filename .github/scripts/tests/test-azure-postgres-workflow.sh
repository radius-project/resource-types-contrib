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
[[ "$(bash "$script" regions)" == westus3,eastus2,centralus ]] || fail defaults
[[ "$(AZURE_LOCATION=eastus AZURE_FALLBACK_LOCATION=northeurope bash "$script" regions)" == \
    eastus,northeurope,centralus ]] || fail "legacy settings"
[[ "$(AZURE_LOCATION=centralus AZURE_FALLBACK_LOCATION=centralus bash "$script" regions)" == \
    centralus ]] || fail "stable deduplication"
[[ "$(RTC_AZURE_TEST_REGIONS=westus2,westus2,eastus2 AZURE_LOCATION=bad bash "$script" regions)" == \
    westus2,eastus2 ]] || fail "override precedence"
[[ "$(RTC_AZURE_TEST_REGIONS=westus3,eastus2,centralus,westus2 bash "$script" regions)" == \
    westus3,eastus2,centralus,westus2 ]] || fail "four-region override"
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
command="$2"
group=""
while (($#)); do
    if [[ "$1" == --name && $# -ge 2 ]]; then
        group="$2"
        shift 2
    else
        shift
    fi
done
case "$command" in
    list)
        if [[ "${LIST_FAILS:-}" == true ]]; then exit 1; fi
        cat "$GROUP_STATE"
        ;;
    exists)
        if grep -Fqx -- "$group" "$GROUP_STATE"; then echo true; else echo false; fi
        ;;
    delete)
        if [[ "${DELETE_FAILS:-}" == true ]]; then exit 1; fi
        if [[ "${DELETE_STUCK:-}" != true ]]; then
            grep -Fvx -- "$group" "$GROUP_STATE" >"$GROUP_STATE.next" || true
            mv "$GROUP_STATE.next" "$GROUP_STATE"
        fi
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$temp/bin/az"
export PATH="$temp/bin:$PATH" GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=3 AZURE_SUBSCRIPTION_ID=test
for kind in nightly rc; do
    printf 'rrttest-%s-123-2-probe\n' "$kind" >"$GROUP_STATE"
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
for group in caller-owned rrttest-nightly-124-2-probe rrttest-rc-123-4-probe \
    rrttest-nightly-123-0-probe rrttest-rc-123-x-probe \
    rrttest-nightly-123-2-probe-suffix; do
    if bash "$script" cleanup-probe "$group" 2>/dev/null; then fail "ownership guard"; fi
done
[[ ! -s "$CALL_LOG" ]] || fail "must reject before Azure calls"
printf 'rrttest-nightly-123-2-probe\n' >"$GROUP_STATE"
if DELETE_FAILS=true bash "$script" cleanup-probe rrttest-nightly-123-2-probe 2>/dev/null; then
    fail "delete error"
fi
if DELETE_STUCK=true bash "$script" cleanup-probe rrttest-nightly-123-2-probe 2>/dev/null; then
    fail "delete must be confirmed"
fi
for attempt in 1 2 3; do
    : >"$GROUP_STATE"
    bash "$script" cleanup-probe "rrttest-nightly-123-$attempt-probe"
done
if GITHUB_RUN_ID=124 bash "$script" cleanup-probe rrttest-nightly-123-2-probe 2>/dev/null; then
    fail "mismatched run ID"
fi
if GITHUB_RUN_ATTEMPT=invalid bash "$script" cleanup-probe rrttest-nightly-123-2-probe 2>/dev/null; then
    fail "invalid current attempt"
fi

# Cleanup-only reruns have no producer outputs; discover exact earlier-attempt groups by run ID.
for kind in nightly rc; do
    cat >"$GROUP_STATE" <<EOF
rrttest-$kind-123-2
rrttest-$kind-123-2-probe
rrttest-$kind-123-4
rrttest-$kind-123-4-probe
rrttest-$kind-123-5
rrttest-$kind-123-5-probe
rrttest-$kind-123-2-extra
rrttest-$kind-123-x-probe
rrttest-$kind-124-2
rrttest-other-123-2
EOF
    : >"$CALL_LOG"
    GITHUB_RUN_ATTEMPT=4 bash "$script" cleanup-run-groups "$kind"
    for group in "rrttest-$kind-123-2" "rrttest-$kind-123-2-probe" \
        "rrttest-$kind-123-4" "rrttest-$kind-123-4-probe"; do
        grep -Fq "delete --name $group --subscription test" "$CALL_LOG" ||
            fail "earlier-attempt cleanup discovery: $group"
    done
    ! grep -Fq -- --no-wait "$CALL_LOG" || fail "all owned group deletions must be confirmed"
    for group in "rrttest-$kind-123-5" "rrttest-$kind-123-5-probe" \
        "rrttest-$kind-123-2-extra" "rrttest-$kind-123-x-probe" \
        "rrttest-$kind-124-2" "rrttest-other-123-2"; do
        ! grep -Fq "delete --name $group " "$CALL_LOG" ||
            fail "ignored unrelated group: $group"
    done
done

# A full rerun may publish attempt-2 outputs while groups from attempt 1 remain.
for kind in nightly rc; do
    cat >"$GROUP_STATE" <<EOF
rrttest-$kind-123-1
rrttest-$kind-123-1-probe
rrttest-$kind-123-2
rrttest-$kind-123-2-probe
rrttest-$kind-123-3
rrttest-$kind-123-3-probe
rrttest-$kind-124-1
rrttest-other-123-1
EOF
    : >"$CALL_LOG"
    AZURE_RESOURCE_GROUP="rrttest-$kind-123-2" \
        PROBE_RESOURCE_GROUP="rrttest-$kind-123-2-probe" GITHUB_RUN_ATTEMPT=2 \
        bash "$script" cleanup-run-groups "$kind"
    for group in "rrttest-$kind-123-1" "rrttest-$kind-123-1-probe" \
        "rrttest-$kind-123-2" "rrttest-$kind-123-2-probe"; do
        grep -Fq "delete --name $group --subscription test" "$CALL_LOG" ||
            fail "cleanup with current outputs missed earlier group: $group"
    done
    for group in "rrttest-$kind-123-3" "rrttest-$kind-123-3-probe" \
        "rrttest-$kind-124-1" "rrttest-other-123-1"; do
        ! grep -Fq "delete --name $group " "$CALL_LOG" ||
            fail "cleanup deleted an unowned or future group: $group"
    done
done

: >"$GROUP_STATE"
LIST_FAILS=true bash "$script" cleanup-run-groups nightly 2>/dev/null &&
    fail "resource group discovery failure"
for kind in nightly rc; do
    printf 'rrttest-%s-123-2\n' "$kind" >"$GROUP_STATE"
    DELETE_FAILS=true GITHUB_RUN_ATTEMPT=3 bash "$script" cleanup-run-groups "$kind" \
        2>/dev/null && fail "resource group delete failure"
    DELETE_STUCK=true GITHUB_RUN_ATTEMPT=3 bash "$script" cleanup-run-groups "$kind" \
        2>/dev/null && fail "resource group deletion must be confirmed"
done
echo "Azure PostgreSQL workflow tests passed"
