#!/bin/bash

# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/logs"
export CALL_LOG="$TEST_ROOT/calls" PATH="$TEST_ROOT/bin:$PATH"
export GITHUB_ACTIONS=true RTC_TEST_PLATFORM=azure AZURE_RESOURCE_GROUP=rg
export TMPDIR="$TEST_ROOT/logs"
unset RTC_AZURE_TEST_STEP_DEADLINE_EPOCH RTC_TEST_DIAGNOSTICS_DIR RTC_AZURE_DIAGNOSTICS_DIR

cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
echo "rad $*" >>"$CALL_LOG"
case "$1 $2" in
    "deploy "*)
        attempt="$(grep -c '^rad deploy ' "$CALL_LOG")"
        if ((attempt <= ${FAILURES:-1})); then
            printf 'Error: %s\n' "$DEPLOY_ERROR" >&2
            exit "${DEPLOY_EXIT_CODE:-1}"
        fi
        ;;
    "resource show")
        if [[ "${ASSERT_FAIL:-0}" == 1 ]]; then exit 1; fi
        if [[ "$4" == myApp ]]; then
            echo '{"properties":{"hosts":{"orderProcessor":"first"}}}'
        else echo '{"properties":{"hosts":{"simple":"second"}}}'; fi
        ;;
    "app delete") exit "${DELETE_FAIL:-0}" ;;
esac
EOF
cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
echo "az $*" >>"$CALL_LOG"
case "$1 $2" in
    "resource list")
        if [[ "${INVENTORY_FAIL:-0}" == 1 ]] ||
            { [[ "${AFTER_INVENTORY_FAIL:-0}" == 1 ]] && grep -q '^rad app delete ' "$CALL_LOG"; }; then exit 1; fi
        if [[ "${LEAK:-0}" == 1 ]] && grep -q '^rad app delete ' "$CALL_LOG"; then
            echo '[{"id":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ContainerInstance/ngroups/leak"}]'
        else echo '[]'; fi
        ;;
    "group delete") exit "${DELETE_FAIL:-0}" ;;
    "group exists")
        if [[ "${INVENTORY_FAIL:-0}" == 1 ]]; then exit 1; fi
        echo "${GROUP_EXISTS:-false}"
        ;;
esac
EOF
cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >>"$CALL_LOG"
exit "${KUBECTL_FAIL:-0}"
EOF
cat >"$TEST_ROOT/bin/sleep" <<'EOF'
#!/bin/bash
echo "sleep $*" >>"$CALL_LOG"
exit "${SLEEP_FAIL:-0}"
EOF
cat >"$TEST_ROOT/bin/timeout" <<'EOF'
#!/bin/bash
echo "timeout $*" >>"$CALL_LOG"
if [[ -n "${OUTER_TIMEOUT:-}" && "$*" == *'rtc_test_azure_aci_app'* ]]; then
    shift 2
    exec /usr/bin/timeout --kill-after=1s "$OUTER_TIMEOUT" "$@"
fi
exec /usr/bin/timeout "$@"
EOF
cat >"$TEST_ROOT/bin/node" <<'EOF'
#!/bin/bash
echo "diagnostics $*" >>"$CALL_LOG"
echo '{}' >"$2/azure.json"
EOF
chmod +x "$TEST_ROOT"/bin/*

# shellcheck source=/dev/null
source "$REPO_ROOT/.github/scripts/lib-recipe-test.sh"
APP="$TEST_ROOT/app.bicep"
printf 'param applicationName string\n' >"$APP"
NGROUP="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ContainerInstance/ngroups/test"
QUOTA="$(jq -cn --arg target "$NGROUP" \
    '{code:"DeploymentFailed",details:[{code:"ResourceDeploymentFailure",target:$target,
      details:[{code:"AzureContainerInstance/ContainerGroupQuotaReached",target:"child-id",
      message:("[{\"ErrorCode\":\"AzureContainerInstance/ContainerGroupQuotaReached\","
      + "\"SampleErrorMessage\":\"StandardCores exceeded in westus3\"}]")}]}]}')"
export DEPLOY_ERROR="$QUOTA"

fail() { echo "FAIL: $*" >&2; exit 1; }
attempts() { [[ "$(grep -c '^rad deploy ' "$CALL_LOG")" == "$1" ]] || fail "expected $1 deployments"; }
run_test() {
    : >"$CALL_LOG"
    rtc_deploy_and_assert_test_app "$APP" Radius.Compute/containers aci-test /envs/test default ns \
        >"$TEST_ROOT/output" 2>&1
}

run_test || { cat "$TEST_ROOT/output"; fail "quota followed by success"; }
attempts 2
[[ "$(grep -c '^rad app delete ' "$CALL_LOG")" == 2 ]] || fail "both attempts need cleanup"
[[ "$(grep -c '^sleep 60$' "$CALL_LOG")" == 1 ]] || fail "one 60-second quota backoff required"
awk '/^rad app delete / { cleaned++ } /^az resource list / { snapshots++ }
    /^rad deploy / { attempts++; if (attempts == 2 && (cleaned != 1 || snapshots < 3)) exit 1 }' "$CALL_LOG" ||
    fail "retry must follow deletion and resource verification"
[[ "$(grep '^rad deploy ' "$CALL_LOG" | sed -E 's/.*applicationName=([^ ]+).*/\1/' | sort -u | wc -l)" == 2 ]] ||
    fail "quota recovery must use a new application name"
grep -Eq '^timeout --kill-after=5s (119[0-9]|1200)s bash -c .*rtc_test_azure_aci_app' "$CALL_LOG" ||
    fail "full ACI test needs a 20-minute limit"
[[ -z "$(find "$TMPDIR" -type f -print -quit)" ]] || fail "deployment transcript leaked"

RTC_TEST_DIAGNOSTICS_DIR="$TEST_ROOT/diagnostics" run_test || fail "quota recovery with diagnostics"
[[ -n "$(find "$TEST_ROOT/diagnostics" -name azure.json -print -quit)" ]] || fail "quota diagnostics not saved"
awk '/^diagnostics / { diagnostics++ } /^rad app delete / { if (!diagnostics) exit 1 }' "$CALL_LOG" ||
    fail "diagnostics must precede cleanup"

if FAILURES=2 run_test; then fail "quota exhaustion must fail"; fi
attempts 2
grep -q 'deployment was not validated' "$TEST_ROOT/output" || fail "exhaustion needs a clear error"

for control in DELETE_FAIL AFTER_INVENTORY_FAIL KUBECTL_FAIL LEAK SLEEP_FAIL ASSERT_FAIL; do
    if (export "$control=1"; run_test); then fail "$control must fail"; fi
    if [[ "$control" == ASSERT_FAIL ]]; then attempts 2; else attempts 1; fi
done
if INVENTORY_FAIL=1 run_test; then fail "failed initial inventory must block allocation"; fi
[[ ! -s "$CALL_LOG" || "$(grep -c '^rad deploy ' "$CALL_LOG")" == 0 ]] || fail "unsafe allocation"

for error in \
    "${QUOTA//ContainerGroupQuotaReached/RegistryErrorResponse}" \
    "${QUOTA//ContainerGroupQuotaReached/InternalOperationError}" \
    "${QUOTA//ContainerGroupQuotaReached/QuotaExceeded}" \
    "${QUOTA//ContainerInstance\/ngroups/Storage\/storageAccounts}" \
    "$(jq -cn --argjson quota "$QUOTA" '{code:"DeploymentFailed",details:[$quota,{code:"AuthorizationFailed",message:"denied"}]}')" \
    "$(jq -cn --argjson quota "$QUOTA" \
        '$quota | .details[0].details[0].message = "[{\"ErrorCode\":\"AzureContainerInstance/ContainerGroupQuotaReached\",\"SampleErrorMessage\":\"quota\"},{\"ErrorCode\":\"RegistryErrorResponse\",\"SampleErrorMessage\":\"registry\"}]"')" \
    "$QUOTA"$'\nError: InvalidTemplate: invalid property' \
    'AzureContainerInstance/ContainerGroupQuotaReached: unstructured error'; do
    if DEPLOY_ERROR="$error" run_test; then fail "unconfirmed or mixed quota must fail"; fi
    attempts 1
    if grep -q '^sleep ' "$CALL_LOG"; then fail "unconfirmed quota must not back off"; fi
done

if GITHUB_ACTIONS=false run_test; then fail "local quota errors must fail without recovery"; fi
attempts 1
if RTC_TEST_PLATFORM=kubernetes run_test; then fail "non-Azure errors must fail without recovery"; fi
attempts 1
for status in 124 137; do
    if DEPLOY_EXIT_CODE="$status" run_test; then fail "deployment timeout must fail"; fi
    attempts 1
done
if DEPLOY_EXIT_CODE=43 DEPLOY_ERROR='InvalidTemplate: invalid property' run_test; then
    fail "a native exit code must not qualify as a quota sentinel"
fi
attempts 1
for deadline in invalid "$(( $(date +%s) + 360 ))"; do
    if RTC_AZURE_TEST_STEP_DEADLINE_EPOCH="$deadline" run_test; then fail "invalid or expired budget"; fi
    [[ ! -s "$CALL_LOG" ]] || fail "invalid budget must block allocation"
done
if RTC_AZURE_TEST_STEP_DEADLINE_EPOCH="$(( $(date +%s) + 415 ))" run_test; then fail "insufficient retry budget"; fi
attempts 1
if grep -q '^sleep ' "$CALL_LOG"; then fail "insufficient retry budget must block backoff"; fi
status=0
OUTER_TIMEOUT=0.001s run_test || status=$?
[[ "$status" == 1 ]] || fail "outer timeout must fail, not pass or redeploy"
grep -q 'ACI test deadline expired' "$TEST_ROOT/output" || fail "outer timeout needs an explicit error"

for result in success deletion-failed still-exists inventory-failed; do
    : >"$CALL_LOG"
    status=0
    (
        case "$result" in
            deletion-failed) export DELETE_FAIL=1 ;;
            still-exists) export GROUP_EXISTS=true ;;
            inventory-failed) export INVENTORY_FAIL=1 ;;
        esac
        bash "$REPO_ROOT/.github/scripts/cleanup-azure-resources.sh"
    ) >"$TEST_ROOT/cleanup-output" 2>&1 || status=$?
    if [[ "$result" == success ]]; then
        [[ "$status" == 0 ]] || fail "confirmed group cleanup"
    else [[ "$status" != 0 ]] || fail "$result must fail group cleanup"; fi
    if grep -q -- '--no-wait' "$CALL_LOG"; then fail "group cleanup must wait"; fi
done

FIXTURE="$TEST_ROOT/repo"
for recipe in Compute/containers/azure/bicep Compute/containers/azure/terraform \
    Compute/containers/kubernetes/bicep Security/secrets/azure/bicep; do
    type="${recipe%/*/*}" platform="${recipe#*/*/}"
    mkdir -p "$FIXTURE/$type/recipes/$platform"
    if [[ "$platform" == */terraform ]]; then touch "$FIXTURE/$type/recipes/$platform/main.tf"
    else touch "$FIXTURE/$type/recipes/$platform/main.bicep"; fi
done
PACK="$TEST_ROOT/pack.bicep"
RECIPE_PLATFORM_FILTER=azure RTC_ACI_TEST_DESIRED_COUNT=1 \
    bash "$REPO_ROOT/.github/scripts/generate-recipe-pack.sh" "$FIXTURE" basic "$PACK" >/dev/null
[[ "$(grep -c 'desiredCount: 1' "$PACK")" == 1 ]] || fail "basic Azure pack needs one ACI count override"
grep -A6 "'Radius.Compute/containers':" "$PACK" | grep -q 'desiredCount: 1' || fail "override on wrong type"
RECIPE_PLATFORM_FILTER=kubernetes RTC_ACI_TEST_DESIRED_COUNT=1 \
    bash "$REPO_ROOT/.github/scripts/generate-recipe-pack.sh" "$FIXTURE" basic "$PACK" >/dev/null
if grep -q desiredCount "$PACK"; then fail "Kubernetes must not receive ACI parameters"; fi
RECIPE_PLATFORM_FILTER=azure RTC_ACI_TEST_DESIRED_COUNT=1 \
    bash "$REPO_ROOT/.github/scripts/generate-recipe-pack.sh" "$FIXTURE" terraform "$PACK" >/dev/null
if grep -q desiredCount "$PACK"; then fail "Terraform must not receive ACI parameters"; fi
RECIPE_PLATFORM_FILTER=azure bash "$REPO_ROOT/.github/scripts/generate-recipe-pack.sh" "$FIXTURE" default "$PACK" >/dev/null
if grep -q desiredCount "$PACK"; then fail "default pack must preserve production count"; fi
for value in '' 0 2 invalid; do
    if RTC_ACI_TEST_DESIRED_COUNT="$value" bash "$REPO_ROOT/.github/scripts/generate-recipe-pack.sh" "$FIXTURE" basic "$PACK" \
        >/dev/null 2>&1; then fail "invalid CI count must fail"; fi
done
grep -q '^param desiredCount int = 3$' \
    "$REPO_ROOT/Compute/containers/recipes/azure/bicep/azure-aci-containers.bicep" || fail "production count changed"
if grep -q desiredCount "$REPO_ROOT/recipe-packs/azure-aci/azure-aci.bicep"; then
    fail "checked-in multi-instance pack must retain recipe defaults"
fi

python3 - "$REPO_ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
for workflow, job, kind in (
    ("validate-azure-recipes", "validate-azure-recipes", None),
    ("nightly-recipe-pack-tests", "nightly-azure-recipe-pack-tests", "nightly"),
    ("release-candidate-recipe-pack-tests", "rc-azure-recipe-pack-tests", "rc"),
):
    source = (root / ".github/workflows" / f"{workflow}.yaml").read_text()
    body = re.search(rf"^  {job}:\n(.*?)(?=^  [\w-]+:|\Z)", source, re.M | re.S).group(1)
    assert re.search(r"^    concurrency:\n      group: azure-recipe-test-capacity\n"
                     r"      cancel-in-progress: false\n      queue: max$", body, re.M), workflow
    if kind:
        assert re.search(r"if: always\(\).*cleanup-run-groups " + kind, body, re.S), workflow
    else:
        assert 'RTC_ACI_TEST_DESIRED_COUNT: "1"' in body
        assert "cancel-in-progress: true" not in source
    if kind == "nightly":
        basic = body.split("- name: Test Azure Bicep recipes", 1)[1]
        assert 'RTC_ACI_TEST_DESIRED_COUNT: "1"' in basic.split("- name:", 1)[0]
        assert 'RTC_ACI_TEST_DESIRED_COUNT: "1"' not in body.split("- name: Test Azure Bicep recipes", 1)[0]
print("Azure capacity queue checks passed")
PY

echo "ACI quota recovery tests passed"
