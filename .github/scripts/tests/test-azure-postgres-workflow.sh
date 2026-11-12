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
for status in selected capacity_exhausted probe_error deadline_exceeded unsupported restricted catalog_unavailable; do
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
query=""
tags=()
while (($#)); do
    case "$1" in
        --name) group="$2"; shift 2 ;;
        --query) query="$2"; shift 2 ;;
        --tags)
            shift
            while (($#)) && [[ "$1" != --* ]]; do tags+=("$1"); shift; done
            ;;
        *) shift ;;
    esac
done
state_line() { grep -F "$1|" "$GROUP_STATE" | head -n 1; }
case "$command" in
    list) [[ "${LIST_FAILS:-}" != true ]] || exit 1; cut -d'|' -f1 "$GROUP_STATE" ;;
    exists)
        if grep -Fq "$group|" "$GROUP_STATE"; then echo true; else echo false; fi
        ;;
    show)
        line="$(state_line "$group")"
        [[ -n "$line" ]] || exit 1
        if [[ "$query" == tags.rtcPostgresSelectorOwner ]]; then
            IFS='|' read -r _ key value <<<"$line"
            [[ "$key" == rtcPostgresSelectorOwner ]] && echo "$value"
        elif [[ "$query" == tags.rtcAzureTestGroupOwner ]]; then
            IFS='|' read -r _ key value <<<"$line"
            [[ "$key" == rtcAzureTestGroupOwner ]] && echo "$value"
        fi
        ;;
    delete)
        if [[ "${DELETE_FAILS:-}" == true ]]; then exit 1; fi
        if [[ "${DELETE_STUCK:-}" != true ]]; then
            grep -Fv "$group|" "$GROUP_STATE" >"$GROUP_STATE.next" || true
            mv "$GROUP_STATE.next" "$GROUP_STATE"
        fi
        ;;
    create)
        owner_tag=""
        owner_value=""
        for tag in "${tags[@]}"; do
            case "$tag" in rtcPostgresSelectorOwner=*) owner_tag=rtcPostgresSelectorOwner; owner_value="${tag#*=}" ;;
                rtcAzureTestGroupOwner=*) owner_tag=rtcAzureTestGroupOwner; owner_value="${tag#*=}" ;;
            esac
        done
        printf '%s|%s|%s\n' "$group" "$owner_tag" "$owner_value" >>"$GROUP_STATE"
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$temp/bin/az"
export PATH="$temp/bin:$PATH" GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=3 AZURE_SUBSCRIPTION_ID=test
token_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
token_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
for kind in nightly rc ci-bicep; do
    group="rrttest-$kind-123-2-probe-$token_a"
    printf '%s|rtcPostgresSelectorOwner|%s\n' "$group" "$token_a" >"$GROUP_STATE"
    : >"$CALL_LOG"
    bash "$script" cleanup-probe "$group"
    grep -q "group delete --name $group --subscription test" "$CALL_LOG" ||
        fail "exact owned group"
    ! grep -q -- --no-wait "$CALL_LOG" || fail "must confirm deletion"
    : >"$CALL_LOG"
    bash "$script" cleanup-probe "$group"
    ! grep -q 'group delete' "$CALL_LOG" || fail "missing group is idempotent"
done
: >"$CALL_LOG"
bash "$script" cleanup-probe ''
for group in caller-owned rrttest-nightly-124-2-probe-$token_a rrttest-rc-123-4-probe-$token_a \
    rrttest-nightly-123-0-probe rrttest-rc-123-x-probe \
    rrttest-nightly-123-2-probe-suffix; do
    if bash "$script" cleanup-probe "$group" 2>/dev/null; then fail "ownership guard"; fi
done
[[ ! -s "$CALL_LOG" ]] || fail "must reject before Azure calls"
group="rrttest-nightly-123-2-probe-$token_a"
printf '%s|rtcPostgresSelectorOwner|%s\n' "$group" "$token_a" >"$GROUP_STATE"
if DELETE_FAILS=true bash "$script" cleanup-probe "$group" 2>/dev/null; then
    fail "delete error"
fi
if DELETE_STUCK=true bash "$script" cleanup-probe "$group" 2>/dev/null; then
    fail "delete must be confirmed"
fi
for attempt in 1 2 3; do
    : >"$GROUP_STATE"
    bash "$script" cleanup-probe "rrttest-nightly-123-$attempt-probe"
done
if GITHUB_RUN_ID=124 bash "$script" cleanup-probe "rrttest-nightly-123-2-probe-$token_a" 2>/dev/null; then
    fail "mismatched run ID"
fi
if GITHUB_RUN_ATTEMPT=invalid bash "$script" cleanup-probe "rrttest-nightly-123-2-probe-$token_a" 2>/dev/null; then
    fail "invalid current attempt"
fi

# Cleanup discovers groups by run ID and attempt, then requires each group's owner tag.
for kind in nightly rc ci-bicep ci-terraform; do
    main2="rrttest-$kind-123-2-$token_a"
    probe2="rrttest-$kind-123-2-probe-$token_b"
    main4="rrttest-$kind-123-4-$token_a"
    probe4="rrttest-$kind-123-4-probe-$token_b"
    cat >"$GROUP_STATE" <<EOF
$main2|rtcAzureTestGroupOwner|$token_a
$probe2|rtcPostgresSelectorOwner|$token_b
$main4|rtcAzureTestGroupOwner|$token_a
$probe4|rtcPostgresSelectorOwner|$token_b
rrttest-$kind-123-5-$token_a|rtcAzureTestGroupOwner|$token_a
rrttest-$kind-123-5-probe-$token_b|rtcPostgresSelectorOwner|$token_b
rrttest-$kind-123-2-extra||
rrttest-$kind-123-x-probe||
rrttest-$kind-124-2-$token_a|rtcAzureTestGroupOwner|$token_a
rrttest-other-123-2-$token_a|rtcAzureTestGroupOwner|$token_a
EOF
    : >"$CALL_LOG"
    GITHUB_RUN_ATTEMPT=4 bash "$script" cleanup-run-groups "$kind"
    for group in "$main2" "$probe2" "$main4" "$probe4"; do
        grep -Fq "delete --name $group --subscription test" "$CALL_LOG" ||
            fail "earlier-attempt cleanup discovery: $group"
    done
    ! grep -Fq -- --no-wait "$CALL_LOG" || fail "all owned group deletions must be confirmed"
    for group in "rrttest-$kind-123-5-$token_a" "rrttest-$kind-123-5-probe-$token_b" \
        "rrttest-$kind-123-2-extra" "rrttest-$kind-123-x-probe" \
        "rrttest-$kind-124-2-$token_a" "rrttest-other-123-2-$token_a"; do
        ! grep -Fq "delete --name $group " "$CALL_LOG" ||
            fail "ignored unrelated group: $group"
    done
done

# Current outputs do not hide earlier groups, and only matching owner tags permit deletion.
for kind in nightly rc ci-bicep ci-terraform; do
    main1="rrttest-$kind-123-1-$token_a"
    probe1="rrttest-$kind-123-1-probe-$token_b"
    main2="rrttest-$kind-123-2-$token_a"
    probe2="rrttest-$kind-123-2-probe-$token_b"
    cat >"$GROUP_STATE" <<EOF
$main1|rtcAzureTestGroupOwner|$token_a
$probe1|rtcPostgresSelectorOwner|$token_b
$main2|rtcAzureTestGroupOwner|$token_a
$probe2|rtcPostgresSelectorOwner|$token_b
rrttest-$kind-123-3-$token_a|rtcAzureTestGroupOwner|$token_a
rrttest-$kind-123-3-probe-$token_b|rtcPostgresSelectorOwner|$token_b
rrttest-$kind-124-1-$token_a|rtcAzureTestGroupOwner|$token_a
rrttest-other-123-1-$token_a|rtcAzureTestGroupOwner|$token_a
EOF
    : >"$CALL_LOG"
    AZURE_RESOURCE_GROUP="$main2" PROBE_RESOURCE_GROUP="$probe2" GITHUB_RUN_ATTEMPT=2 \
        bash "$script" cleanup-run-groups "$kind"
    for group in "$main1" "$probe1" "$main2" "$probe2"; do
        grep -Fq "delete --name $group --subscription test" "$CALL_LOG" ||
            fail "cleanup with current outputs missed earlier group: $group"
    done
    for group in "rrttest-$kind-123-3-$token_a" "rrttest-$kind-123-3-probe-$token_b" \
        "rrttest-$kind-124-1-$token_a" "rrttest-other-123-1-$token_a"; do
        ! grep -Fq "delete --name $group " "$CALL_LOG" ||
            fail "cleanup deleted an unowned or future group: $group"
    done
done

# Exact legacy names and forged/mismatched owner tags are never deleted.
for kind in nightly rc ci-bicep ci-terraform; do
    cat >"$GROUP_STATE" <<EOF
rrttest-$kind-123-2||
rrttest-$kind-123-2-probe||
rrttest-$kind-123-2-$token_a|rtcAzureTestGroupOwner|$token_b
rrttest-$kind-123-2-probe-$token_a|rtcPostgresSelectorOwner|$token_b
EOF
    : >"$CALL_LOG"
    if bash "$script" cleanup-run-groups "$kind" 2>/dev/null; then fail "unowned groups must fail cleanup"; fi
    ! grep -q 'group delete' "$CALL_LOG" || fail "unowned groups must not be deleted"
done

: >"$GROUP_STATE"
LIST_FAILS=true bash "$script" cleanup-run-groups nightly 2>/dev/null &&
    fail "resource group discovery failure"
for kind in nightly rc ci-bicep ci-terraform; do
    printf 'rrttest-%s-123-2-%s|rtcAzureTestGroupOwner|%s\n' "$kind" "$token_a" "$token_a" >"$GROUP_STATE"
    DELETE_FAILS=true GITHUB_RUN_ATTEMPT=3 bash "$script" cleanup-run-groups "$kind" \
        2>/dev/null && fail "resource group delete failure"
    DELETE_STUCK=true GITHUB_RUN_ATTEMPT=3 bash "$script" cleanup-run-groups "$kind" \
        2>/dev/null && fail "resource group deletion must be confirmed"
done

# Main-group creation refuses an existing exact name and marks only its new target as owned.
for kind in nightly rc ci-bicep ci-terraform; do
    : >"$GROUP_STATE"
    group="rrttest-$kind-123-3-$token_a"
    bash "$script" create-main "$kind" "$group" westus3 "$token_a" >/dev/null
    grep -Fq "$group|rtcAzureTestGroupOwner|$token_a" "$GROUP_STATE" ||
        fail "main group ownership tag"
    : >"$CALL_LOG"
    bash "$script" cleanup-run-groups "$kind"
    grep -q 'group delete' "$CALL_LOG" && [[ ! -s "$GROUP_STATE" ]] ||
        fail "owned main group cleanup"
    printf '%s||\n' "$group" >"$GROUP_STATE"
    : >"$CALL_LOG"
    if bash "$script" create-main "$kind" "$group" westus3 "$token_a" 2>/dev/null; then
        fail "existing main group must be rejected"
    fi
    ! grep -q '^group create' "$CALL_LOG" || fail "must not update existing main group"
    grep -Fq "$group||" "$GROUP_STATE" || fail "existing main group preserved"
done

# Execute the real CI shell steps with a stub selector and owned-group Azure mock.
fixture="$temp/repo"
mkdir -p "$fixture/.github/scripts" "$fixture/recipe-packs/azure-aks" \
    "$fixture/Data/postgreSqlDatabases/recipes/azure/bicep"
cp "$root/.github/scripts/lib-azure-postgres-test.sh" "$fixture/.github/scripts/"
cp "$script" "$fixture/.github/scripts/"
cp "$root/recipe-packs/azure-aks/azure-aks.bicep" "$fixture/recipe-packs/azure-aks/"
cp "$root/Data/postgreSqlDatabases/recipes/azure/bicep/azure-postgresql.bicep" \
    "$fixture/Data/postgreSqlDatabases/recipes/azure/bicep/"
cat >"$fixture/.github/scripts/select-azure-test-location.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "selector $1 $RTC_AZURE_TEST_REGIONS $RTC_POSTGRES_TEST_SIZES $RTC_POSTGRES_PROBE_OWNER_TOKEN" >>"$CALL_LOG"
[[ "${SELECTOR_FAILS:-false}" != true ]] || exit 1
jq -n '{version:1,status:"selected",location:"eastus2",attempts:[],
    postgres:{size:"M",skuName:"Standard_D2ds_v5",tier:"GeneralPurpose"}}' >"$RTC_AZURE_SELECTION_FILE"
EOF
python3 - "$root/.github/workflows/validate-azure-recipes.yaml" "$temp" <<'PY'
import pathlib
import re
import sys
import textwrap

workflow = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
for name, filename in [
    ("Set Azure Test Context", "context.sh"),
    ("Select Azure PostgreSQL capacity", "select.sh"),
    ("Create Azure Resource Group", "create.sh"),
]:
    step = re.search(
        r"(?m)^      - name: " + re.escape(name) + r"\n([\s\S]*?)(?=^      - name: |\Z)",
        workflow,
    )
    assert step, name
    if filename == "select.sh":
        assert "if: matrix.recipe == 'bicep'" in step[1]
        assert 'RTC_POSTGRES_PREFLIGHT_TIMEOUT_SECONDS: "2700"' in step[1]
        assert 'RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS: "900"' in step[1]
    script = re.search(r"(?m)^        run: \|\n((?:          .*\n|\n)+)", step[1])
    assert script, name
    text = textwrap.dedent(script[1])
    for expression, value in [
        ("github.run_id", "123"), ("github.run_attempt", "3"), ("matrix.recipe", "bicep")
    ]:
        text = text.replace("${{ " + expression + " }}", value)
    assert "${{" not in text, name
    pathlib.Path(sys.argv[2], filename).write_text(text, encoding="utf-8")
cleanup = workflow.split("\n  cleanup-azure-resources:\n", 1)[1]
assert "always() &&" in cleanup
assert "needs.approval-gate.result == 'success'" in cleanup
assert "needs.check-trust.outputs.is-external == 'false'" in cleanup
assert "ref: ${{ github.event.pull_request.head.sha || github.sha }}" in cleanup
assert "persist-credentials: false" in cleanup
assert "if: needs.validate-azure-recipes.result != 'success'" in cleanup
assert "run: sleep 180" in cleanup
test_step = workflow.split("      - name: Test Azure ${{ matrix.recipe }} Recipes\n", 1)[1]
test_step = test_step.split("\n      - name:", 1)[0]
assert "RTC_POSTGRES_RECIPE_SELECTION_FILE: ${{ env.RTC_AZURE_SELECTION_FILE }}" in test_step
PY
(
    cd "$fixture"
    export GITHUB_ENV="$temp/github-env" GITHUB_OUTPUT="$temp/github-output"
    export DEFAULT_AZURE_LOCATION=westus3
    export RTC_AZURE_SELECTION_FILE="$temp/ci-diagnostics/postgres-selection.json"
    unset AZURE_LOCATION RTC_AZURE_TEST_REGIONS
    bash "$temp/context.sh"
    set -a
    # shellcheck source=/dev/null
    source "$GITHUB_ENV"
    set +a
    export REGION_OVERRIDE=centralus,eastus2 AZURE_FALLBACK_LOCATION=westus2 SIZE_OVERRIDE=M,S
    export RTC_POSTGRES_PREFLIGHT_TIMEOUT_SECONDS=2700 RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS=900
    : >"$CALL_LOG"
    bash "$temp/select.sh"
    set -a
    # shellcheck source=/dev/null
    source "$GITHUB_ENV"
    set +a
    [[ "$AZURE_LOCATION" == eastus2 ]] || fail "CI must carry selected region to later steps"
    grep -Fq "selector $AZURE_PROBE_RESOURCE_GROUP centralus,eastus2 M,S $AZURE_GROUP_OWNER_TOKEN" \
        "$CALL_LOG" || fail "CI must pass approved regions, sizes, and ownership to the shared selector"
    : >"$GROUP_STATE"
    bash "$temp/create.sh" >/dev/null
    grep -Fq -- "--location eastus2 --name $AZURE_RESOURCE_GROUP" "$CALL_LOG" ||
        fail "main CI group must use the selected region, not westus3"
    SELECTOR_FAILS=true bash "$temp/select.sh" >/dev/null 2>&1 &&
        fail "selector errors must fail the CI step"
    bash "$script" cleanup-run-groups ci-bicep >/dev/null
)
echo "Azure PostgreSQL workflow tests passed"
