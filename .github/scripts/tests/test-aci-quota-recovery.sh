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
    "app delete")
        if [[ "${CLEANUP_BUDGET_REQUIRED:-0}" == 1 && "${TEST_TIMEOUT_BUDGET:-}" != 6m ]]; then exit 124; fi
        exit "${DELETE_FAIL:-0}" ;;
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
        if [[ "${INVENTORY_FAIL:-0}" != 0 ]]; then exit "$INVENTORY_FAIL"; fi
        if grep -q '^az group delete ' "$CALL_LOG"; then
            if [[ "${AFTER_INVENTORY_FAIL:-0}" == 1 ]]; then exit 1; fi
            echo "${GROUP_EXISTS_AFTER:-false}"
        else echo "${GROUP_EXISTS:-true}"; fi
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
export TEST_TIMEOUT_BUDGET="$2"
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
QUOTA_JSON="$(jq -cn --arg target "$NGROUP" \
    '{code:"DeploymentFailed",details:[{code:"ResourceDeploymentFailure",target:$target,
      details:[{code:"AzureContainerInstance/ContainerGroupQuotaReached",target:"child-id",
      message:("[{\"ErrorCode\":\"AzureContainerInstance/ContainerGroupQuotaReached\","
      + "\"SampleErrorMessage\":\"StandardCores exceeded in westus3\"}]")}]}]}')"
QUOTA="$QUOTA_JSON"
QUOTA+=$'\nTraceId: 0123456789abcdef0123456789abcdef'
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

CLEANUP_BUDGET_REQUIRED=1 run_test || fail "ACI cleanup must allow dependency retries on both attempts"
[[ "$(grep -c '^timeout --kill-after=5s 6m rad app delete ' "$CALL_LOG")" == 2 ]] ||
    fail "successful and failed ACI deployments need six-minute cleanup"
grep -Eq '^timeout --kill-after=5s (53[0-9]|540)s bash -c .*rtc_deploy_with_retry' "$CALL_LOG" ||
    fail "ACI deployment must reserve eleven minutes for cleanup and diagnostics"
[[ "$(grep -c '^timeout --kill-after=5s 30s kubectl delete ' "$CALL_LOG")" == 3 ]] ||
    fail "successful deployment Kubernetes cleanup must be bounded"
[[ "$(grep -c '^kubectl delete .*--request-timeout=10s --wait=false$' "$CALL_LOG")" == 3 ]] ||
    fail "failed deployment Kubernetes cleanup must be bounded"

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
for status in 124 137; do
    if DELETE_FAIL="$status" run_test; then fail "cleanup timeout must fail"; fi
    attempts 1
    if grep -q '^sleep ' "$CALL_LOG"; then fail "cleanup timeout must block quota retry"; fi
done
FAILURES=0 CLEANUP_BUDGET_REQUIRED=1 run_test || fail "successful deployment cleanup budget"
attempts 1
if INVENTORY_FAIL=1 run_test; then fail "failed initial inventory must block allocation"; fi
[[ ! -s "$CALL_LOG" || "$(grep -c '^rad deploy ' "$CALL_LOG")" == 0 ]] || fail "unsafe allocation"

for error in \
    "${QUOTA//ContainerGroupQuotaReached/RegistryErrorResponse}" \
    "${QUOTA//ContainerGroupQuotaReached/InternalOperationError}" \
    "${QUOTA//ContainerGroupQuotaReached/QuotaExceeded}" \
    "${QUOTA//ContainerInstance\/ngroups/Storage\/storageAccounts}" \
    "$(jq -cn --argjson quota "$QUOTA_JSON" '{code:"DeploymentFailed",details:[$quota,{code:"AuthorizationFailed",message:"denied"}]}')" \
    "$(jq -cn --argjson quota "$QUOTA_JSON" \
        '$quota | .details[0].details[0].message = "[{\"ErrorCode\":\"AzureContainerInstance/ContainerGroupQuotaReached\",\"SampleErrorMessage\":\"quota\"},{\"ErrorCode\":\"RegistryErrorResponse\",\"SampleErrorMessage\":\"registry\"}]"')" \
    "$QUOTA"$'\nError: InvalidTemplate: invalid property' \
    "${QUOTA/0123456789abcdef0123456789abcdef/0123456789abcdef0123456789abcdeg}" \
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
for deadline in invalid "$(( $(date +%s) + 660 ))"; do
    if RTC_AZURE_TEST_STEP_DEADLINE_EPOCH="$deadline" run_test; then fail "invalid or expired budget"; fi
    [[ ! -s "$CALL_LOG" ]] || fail "invalid budget must block allocation"
done
if RTC_AZURE_TEST_STEP_DEADLINE_EPOCH="$(( $(date +%s) + 715 ))" run_test; then fail "insufficient retry budget"; fi
attempts 1
if grep -q '^sleep ' "$CALL_LOG"; then fail "insufficient retry budget must block backoff"; fi
status=0
OUTER_TIMEOUT=0.001s run_test || status=$?
[[ "$status" == 1 ]] || fail "outer timeout must fail, not pass or redeploy"
grep -q 'ACI test deadline expired' "$TEST_ROOT/output" || fail "outer timeout needs an explicit error"

for result in success already-absent deletion-failed still-exists inventory-failed \
    verification-failed invalid-inventory invalid-verification delete-timeout read-timeout; do
    : >"$CALL_LOG"
    status=0
    (
        case "$result" in
            deletion-failed) export DELETE_FAIL=1 ;;
            delete-timeout) export DELETE_FAIL=124 ;;
            read-timeout) export INVENTORY_FAIL=124 ;;
            already-absent) export GROUP_EXISTS=false ;;
            still-exists) export GROUP_EXISTS_AFTER=true ;;
            inventory-failed) export INVENTORY_FAIL=1 ;;
            verification-failed) export AFTER_INVENTORY_FAIL=1 ;;
            invalid-inventory) export GROUP_EXISTS=unknown ;;
            invalid-verification) export GROUP_EXISTS_AFTER=unknown ;;
        esac
        bash "$REPO_ROOT/.github/scripts/cleanup-azure-resources.sh"
    ) >"$TEST_ROOT/cleanup-output" 2>&1 || status=$?
    if [[ "$result" == success || "$result" == already-absent ]]; then
        [[ "$status" == 0 ]] || fail "confirmed group cleanup"
    else [[ "$status" != 0 ]] || fail "$result must fail group cleanup"; fi
    if [[ "$result" == already-absent || "$result" == inventory-failed ||
          "$result" == invalid-inventory || "$result" == read-timeout ]]; then
        if grep -q '^az group delete ' "$CALL_LOG"; then fail "$result must not delete"; fi
    else
        [[ "$(grep -c '^az group exists ' "$CALL_LOG")" == 2 ]] ||
            fail "$result must verify deletion"
    fi
    if grep -q -- '--no-wait' "$CALL_LOG"; then fail "group cleanup must wait"; fi
done

FIXTURE="$TEST_ROOT/repo"
for recipe in Compute/containers/azure/bicep Compute/containers/azure/terraform \
    Compute/containers/kubernetes/bicep Security/secrets/azure/bicep \
    Security/secrets/kubernetes/bicep Security/secrets/azure/terraform \
    Security/secrets/kubernetes/terraform; do
    type="${recipe%/*/*}" platform="${recipe#*/*/}"
    mkdir -p "$FIXTURE/$type/recipes/$platform"
    if [[ "$platform" == */terraform ]]; then touch "$FIXTURE/$type/recipes/$platform/main.tf"
    else touch "$FIXTURE/$type/recipes/$platform/main.bicep"; fi
done
mkdir -p "$FIXTURE/.github/scripts"
cp "$REPO_ROOT/.github/scripts/"{generate-recipe-pack,list-recipe-folders,lib-recipe-platform-filter}.sh \
    "$FIXTURE/.github/scripts/"
GENERATOR="$FIXTURE/.github/scripts/generate-recipe-pack.sh"
PACK="$TEST_ROOT/pack.bicep"
RECIPE_PLATFORM_FILTER=azure RTC_ACI_TEST_DESIRED_COUNT=1 \
    bash "$GENERATOR" "$FIXTURE" basic "$PACK" >/dev/null
[[ "$(grep -c 'desiredCount: 1' "$PACK")" == 1 ]] || fail "basic Azure pack needs one ACI count override"
grep -A6 "'Radius.Compute/containers':" "$PACK" | grep -q 'desiredCount: 1' || fail "override on wrong type"
RECIPE_PLATFORM_FILTER=kubernetes RTC_ACI_TEST_DESIRED_COUNT=1 \
    bash "$GENERATOR" "$FIXTURE" basic "$PACK" >/dev/null
if grep -q desiredCount "$PACK"; then fail "Kubernetes must not receive ACI parameters"; fi
RECIPE_PLATFORM_FILTER=azure RTC_ACI_TEST_DESIRED_COUNT=1 \
    bash "$GENERATOR" "$FIXTURE" terraform "$PACK" >/dev/null
if grep -q desiredCount "$PACK"; then fail "Terraform must not receive ACI parameters"; fi
RTC_ACI_TEST_SCOPE=exclude RECIPE_PLATFORM_FILTER=azure \
    bash "$GENERATOR" "$FIXTURE" terraform "$PACK" >/dev/null
[[ "$(grep -c "'Radius.Security/secrets':" "$PACK")" == 1 ]] ||
    fail "Terraform pack must retain one secrets entry"
grep -A4 "'Radius.Security/secrets':" "$PACK" | grep -q '/secrets-azure.zip' ||
    fail "ACI exclusion must not change the Terraform secrets backend"
RECIPE_PLATFORM_FILTER=azure bash "$GENERATOR" "$FIXTURE" default "$PACK" >/dev/null
if grep -q desiredCount "$PACK"; then fail "default pack must preserve production count"; fi
grep -A4 "'Radius.Security/secrets':" "$PACK" | grep -q '/secrets/azure/bicep/main:latest' ||
    fail "default Azure selection must retain Key Vault"
for value in '' 0 2 invalid; do
    if RTC_ACI_TEST_DESIRED_COUNT="$value" bash "$GENERATOR" "$FIXTURE" basic "$PACK" \
        >/dev/null 2>&1; then fail "invalid CI count must fail"; fi
done

for scope in only exclude; do
    RTC_ACI_TEST_SCOPE="$scope" RECIPE_PLATFORM_FILTER=azure \
        bash "$GENERATOR" "$FIXTURE" basic "$PACK" >/dev/null
    if [[ "$scope" == only ]]; then
        grep -q "'Radius.Compute/containers':" "$PACK" || fail "ACI-only pack lost containers"
        ! grep -q "'Radius.Security/secrets':" "$PACK" || fail "ACI-only scope included independent recipes"
    else
        [[ "$(grep -c "'Radius.Compute/containers':" "$PACK")" == 1 ]] ||
            fail "general Azure pack needs one container dependency"
        grep -A4 "'Radius.Compute/containers':" "$PACK" |
            grep -q '/containers/kubernetes/bicep/main:latest' ||
            fail "general Azure pack must use Kubernetes containers, not ACI"
        [[ "$(grep -c "'Radius.Security/secrets':" "$PACK")" == 1 ]] ||
            fail "general Azure pack needs one secrets dependency"
        grep -A4 "'Radius.Security/secrets':" "$PACK" |
            grep -q '/secrets/kubernetes/bicep/main:latest' ||
            fail "model client API keys must use Kubernetes secrets, not Key Vault"
    fi
done
(
    cd "$FIXTURE"
    RTC_ACI_TEST_SCOPE=exclude RECIPE_PLATFORM_FILTER=azure,kubernetes \
        bash "$GENERATOR" . basic "$PACK" >/dev/null
)
[[ "$(grep -c "'Radius.Compute/containers':" "$PACK")" == 1 ]] ||
    fail "Kubernetes pack must not duplicate its container recipe"
[[ "$(grep -c "'Radius.Security/secrets':" "$PACK")" == 1 ]] ||
    fail "mixed-platform pack must not duplicate its secrets recipe"
grep -A4 "'Radius.Security/secrets':" "$PACK" |
    grep -q '/secrets/kubernetes/bicep/main:latest' ||
    fail "mixed-platform pack must select Kubernetes secrets"
mv "$FIXTURE/Compute/containers/recipes/kubernetes/bicep" "$TEST_ROOT/container-dependency"
if RTC_ACI_TEST_SCOPE=exclude RECIPE_PLATFORM_FILTER=azure \
    bash "$GENERATOR" "$FIXTURE" basic "$PACK" \
    >"$TEST_ROOT/missing-dependency-output" 2>&1; then
    fail "missing Kubernetes container dependency must fail generation"
fi
grep -q 'Error: Kubernetes Compute/containers dependency not found' "$TEST_ROOT/missing-dependency-output" ||
    fail "missing dependency needs an explicit error"
mv "$TEST_ROOT/container-dependency" "$FIXTURE/Compute/containers/recipes/kubernetes/bicep"
mv "$FIXTURE/Security/secrets/recipes/kubernetes/bicep" "$TEST_ROOT/secret-dependency"
if RTC_ACI_TEST_SCOPE=exclude RECIPE_PLATFORM_FILTER=azure \
    bash "$GENERATOR" "$FIXTURE" basic "$PACK" \
    >"$TEST_ROOT/missing-dependency-output" 2>&1; then
    fail "missing Kubernetes secrets dependency must fail generation"
fi
grep -q 'Error: Kubernetes Security/secrets dependency not found' "$TEST_ROOT/missing-dependency-output" ||
    fail "missing secrets dependency needs an explicit error"
mv "$TEST_ROOT/secret-dependency" "$FIXTURE/Security/secrets/recipes/kubernetes/bicep"
RTC_ACI_TEST_SCOPE=all RECIPE_PLATFORM_FILTER=azure \
    bash "$GENERATOR" \
        "$FIXTURE/Security/secrets" azuresecretsrecipepack "$PACK" >/dev/null
[[ "$(grep -c "'Radius.Security/secrets':" "$PACK")" == 1 ]] ||
    fail "separate Azure secrets pack needs exactly one secrets recipe"
grep -A4 "'Radius.Security/secrets':" "$PACK" | grep -q '/secrets/azure/bicep/main:latest' ||
    fail "separate Azure secrets phase must retain Key Vault coverage"
! grep -q "'Radius.Compute/containers':" "$PACK" || fail "separate secrets pack must stay scoped"
if RTC_ACI_TEST_SCOPE=invalid bash "$GENERATOR" \
    "$FIXTURE" basic "$PACK" >/dev/null 2>&1; then fail "invalid scope must fail generation"; fi

mkdir -p "$FIXTURE/.github/scripts"
cat >"$FIXTURE/.github/scripts/test-recipe.sh" <<'EOF'
#!/bin/bash
echo "$1" >>"$CALL_LOG"
EOF
chmod +x "$FIXTURE/.github/scripts/test-recipe.sh"
for scope in only exclude; do
    : >"$CALL_LOG"
    (cd "$FIXTURE" && RTC_ACI_TEST_SCOPE="$scope" RECIPE_PLATFORM_FILTER=azure \
        bash "$REPO_ROOT/.github/scripts/test-all-recipes.sh" "$FIXTURE" default bicep >/dev/null) ||
        fail "scoped per-recipe runner"
    [[ "$(wc -l <"$CALL_LOG")" == 1 ]] || fail "each scope must select exactly one fixture recipe"
    if [[ "$scope" == only ]]; then
        grep -q '/Compute/containers/recipes/azure/bicep$' "$CALL_LOG" || fail "ACI runner selected wrong recipe"
    else
        grep -q '/Security/secrets/recipes/azure/bicep$' "$CALL_LOG" || fail "general Azure runner selected ACI"
    fi
done
: >"$CALL_LOG"
RTC_ACI_TEST_SCOPE=exclude RECIPE_PLATFORM_FILTER=azure \
    bash "$REPO_ROOT/.github/scripts/list-recipe-folders.sh" "$FIXTURE" terraform >"$TEST_ROOT/folders"
grep -q '/Compute/containers/recipes/azure/terraform$' "$TEST_ROOT/folders" ||
    fail "ACI exclusion must not suppress Terraform"
if RTC_ACI_TEST_SCOPE=invalid bash "$REPO_ROOT/.github/scripts/test-all-recipes.sh" \
    "$FIXTURE" default bicep >/dev/null 2>&1; then fail "invalid scope must fail testing"; fi
mkdir -p "$TEST_ROOT/empty-repo"
if RTC_ACI_TEST_SCOPE=only bash "$REPO_ROOT/.github/scripts/test-all-recipes.sh" \
    "$TEST_ROOT/empty-repo" default bicep >"$TEST_ROOT/empty-output" 2>&1; then
    fail "an empty ACI test scope must not pass"
fi
grep -q 'Error: no ACI recipes found to test.' "$TEST_ROOT/empty-output" ||
    fail "empty ACI scope needs an explicit error"
grep -q '^param desiredCount int = 3$' \
    "$REPO_ROOT/Compute/containers/recipes/azure/bicep/azure-aci-containers.bicep" || fail "production count changed"
if grep -q desiredCount "$REPO_ROOT/recipe-packs/azure-aci/azure-aci.bicep"; then
    fail "checked-in multi-instance pack must retain recipe defaults"
fi

mkdir -p "$FIXTURE/AI/models/recipes/azure/bicep" "$FIXTURE/Data/unrelated/recipes/azure/bicep"
touch "$FIXTURE/AI/models/recipes/azure/bicep/model.bicep" \
    "$FIXTURE/Data/unrelated/recipes/azure/bicep/unrelated.bicep"
for discovery_root in "$FIXTURE/AI/models" ./AI/models; do
    (
        if [[ "$discovery_root" == ./* ]]; then
            cd "$FIXTURE"
        else
            cd "$TEST_ROOT"
        fi
        RTC_ACI_TEST_SCOPE=exclude RECIPE_PLATFORM_FILTER=azure \
            bash "$GENERATOR" "$discovery_root" basic "$PACK" >/dev/null
    ) || fail "scoped model pack must resolve dependencies from the checkout root"
    [[ "$(grep -c "^      'Radius\\." "$PACK")" == 3 ]] ||
        fail "scoped model pack must contain only the model and its two dependencies"
    for entry in "AI/models|models/azure/bicep/model" \
        "Compute/containers|containers/kubernetes/bicep/main" \
        "Security/secrets|secrets/kubernetes/bicep/main"; do
        resource_type="${entry%%|*}" recipe_source="${entry#*|}"
        [[ "$(grep -Fc "'Radius.$resource_type':" "$PACK")" == 1 ]] ||
            fail "scoped model pack needs one $resource_type entry"
        grep -A4 "'Radius.$resource_type':" "$PACK" | grep -Fq "/$recipe_source:latest" ||
            fail "scoped model pack selected the wrong source for $resource_type"
    done
done

python3 - "$REPO_ROOT" <<'PY'
import pathlib
import re
import os
import subprocess
import sys
import tempfile
import textwrap

root = pathlib.Path(sys.argv[1])
workflow_dir = root / ".github/workflows"

validation = (workflow_dir / "validate-azure-recipes.yaml").read_text()
secret_phase = validation.split("- name: Test Azure Bicep secrets Recipe\n", 1)[1].split("- name:", 1)[0]
assert "if: matrix.recipe == 'bicep'" in secret_phase
assert "RTC_ACI_TEST_SCOPE: all" in secret_phase
assert "RECIPE_PLATFORM_FILTER: azure" in secret_phase
assert validation.index("- name: Test Azure Bicep secrets Recipe") < validation.index("- name: Generate Azure Recipe Pack")
secret_command = textwrap.dedent(secret_phase.split("        run: |\n", 1)[1])
with tempfile.TemporaryDirectory(prefix="rtc-azure-secret-phase-") as directory:
    directory = pathlib.Path(directory)
    binary = directory / "make"
    binary.write_text(
        '#!/bin/bash\n'
        'printf "%s|%s|" "$RTC_ACI_TEST_SCOPE" "$RECIPE_PLATFORM_FILTER" >>"$CALL_LOG"\n'
        'printf "<%s>" "$@" >>"$CALL_LOG"\n'
        'printf "\\n" >>"$CALL_LOG"\n')
    binary.chmod(0o755)
    log = directory / "calls"
    subprocess.run(["bash", "-eu", "-c", secret_command], check=True, cwd=directory,
                   env={**os.environ, "PATH": f"{directory}:{os.environ['PATH']}",
                        "RTC_ACI_TEST_SCOPE": "all", "RECIPE_PLATFORM_FILTER": "azure",
                        "AZURE_ENVIRONMENT_NAME": "test-azure", "CALL_LOG": str(log)})
    assert log.read_text().splitlines() == [
        f"all|azure|<generate-recipe-pack><RESOURCE_TYPE_ROOT={directory}/Security/secrets>"
        "<PACK_NAME=azuresecretsrecipepack><OUTPUT_FILE=recipe-pack-azure-secrets.bicep>",
        "all|azure|<deploy-recipe-pack><BICEP_FILE=recipe-pack-azure-secrets.bicep><RESOURCE_GROUP=default>",
        "all|azure|<update-env-recipe-pack><RECIPE_PACK_NAME=azuresecretsrecipepack><ENVIRONMENT=test-azure>",
        f"all|azure|<test><RESOURCE_TYPE_ROOT={directory}/Security/secrets>"
        "<ENVIRONMENT=test-azure><RECIPE_TYPE=bicep>",
    ]

for workflow, job, kind in (
    ("validate-azure-recipes", "validate-azure-recipes", None),
    ("nightly-recipe-pack-tests", "nightly-azure-recipe-pack-tests", "nightly"),
    ("release-candidate-recipe-pack-tests", "rc-azure-recipe-pack-tests", "rc"),
):
    source = (workflow_dir / f"{workflow}.yaml").read_text()
    body = re.search(rf"^  {job}:\n(.*?)(?=^  [\w-]+:|\Z)", source, re.M | re.S).group(1)
    assert "concurrency:" not in body, workflow
    assert "RTC_ACI_TEST_SCOPE: exclude" in body, workflow
    assert "RTC_ACI_TEST_DESIRED_COUNT" not in body, workflow
    if kind:
        assert re.search(r"if: always\(\).*cleanup-run-groups " + kind, body, re.S), workflow
    else:
        assert "cancel-in-progress: true" not in source

worker = (workflow_dir / "test-azure-aci.yaml").read_text()
assert "group: azure-aci-test-capacity-${{ needs.select-slot.outputs.slot }}" in worker
assert "cancel-in-progress: false\n      queue: max" in worker
slot_command = re.search(r'run: (echo "slot=.*)', worker).group(1)
slots = set()
with tempfile.TemporaryDirectory(prefix="rtc-aci-slots-") as directory:
    output = pathlib.Path(directory) / "output"
    for run_id in range(42686076121, 42686076133):
        output.write_text("")
        subprocess.run(["bash", "-c", slot_command], check=True,
                       env={**os.environ, "GITHUB_RUN_ID": str(run_id), "GITHUB_OUTPUT": str(output)})
        slot = int(output.read_text().strip().split("=")[1])
        assert slot == run_id % 4
        slots.add(slot)
assert slots == {0, 1, 2, 3}
assert re.search(r"name: Release ACI capacity.*?if: always\(\).*?run: make cleanup-azure-resources",
                 worker, re.S)
assert "rrttest-${{ github.run_id }}-${{ github.run_attempt }}-aci" in worker
assert "RTC_ACI_TEST_SCOPE: only" in worker
assert "RTC_ACI_TEST_SCOPE=only RECIPE_PLATFORM_FILTER=azure make test" in worker
assert 'if [[ "$RELEASE_CANDIDATE" != true ]]; then\n            export RTC_ACI_TEST_DESIRED_COUNT=1' in worker
pack_step = worker.split("- name: Test checked-in ACI Recipe Pack entry", 1)[1].split("- name:", 1)[0]
assert "RTC_ACI_TEST_DESIRED_COUNT" not in pack_step
for step_name in ("Deploy checked-in ACI Recipe Pack", "Test checked-in ACI Recipe Pack entry",
                  "Test generated ACI Bicep recipe"):
    step = worker.split(f"- name: {step_name}", 1)[1].split("- name:", 1)[0]
    assert "continue-on-error:" not in step, step_name
assert "RECIPE_PACK_USE_LOCAL_RECIPES: ${{ !inputs.release_candidate && 'true' || 'false' }}" in worker
assert "prepare-release-candidate-sources.sh" in worker
assert "verify-recipe-pack-sources.sh" in worker
ci = (workflow_dir / "validate-azure-aci-recipes.yaml").read_text()
assert "pull_request_target:" in ci and "merge_group:" in ci
assert "environment: azure" in ci
assert "needs.check-trust.result == 'success'" in ci
assert "needs.approval-gate.result == 'success'" in ci
assert "needs.check-trust.outputs.is-external == 'false'" in ci
assert "checkout_ref: ${{ github.event.pull_request.head.sha || github.sha }}" in ci
assert "uses: ./.github/workflows/test-azure-aci.yaml" in ci
result_job = ci.split("  aci-validation-result:", 1)[1]
assert "if: always()" in result_job
result_command = textwrap.dedent(result_job.split("        run: |\n", 1)[1])
for path_result in ("success", "failure", "cancelled", "skipped"):
    for changed in ("true", "false", "", "invalid"):
        for test_result in ("success", "failure", "cancelled", "skipped"):
            result = subprocess.run(
                ["bash", "-c", result_command], capture_output=True, text=True,
                env={**os.environ, "PATH_RESULT": path_result,
                     "ACI_CHANGED": changed, "TEST_RESULT": test_result})
            should_pass = path_result == "success" and (
                changed == "false" or changed == "true" and test_result == "success")
            assert (result.returncode == 0) == should_pass, (
                path_result, changed, test_result, result.stdout, result.stderr)
            if not should_pass:
                assert "::error::ACI validation did not pass" in result.stdout
nightly = (workflow_dir / "nightly-azure-aci-tests.yaml").read_text()
assert nightly.count('cron: "0 9 * * *"') == 1
assert "uses: ./.github/workflows/test-azure-aci.yaml" in nightly
assert "test_checked_in_pack: true" in nightly
rc = (workflow_dir / "release-candidate-recipe-pack-tests.yaml").read_text()
assert "rc-azure-aci-tests:" in rc and "release_candidate: true" in rc
assert "uses: ./.github/workflows/test-azure-aci.yaml" in rc
assert "azure-recipe-test-capacity" not in "".join(
    path.read_text() for path in workflow_dir.glob("*.yaml"))
print("ACI workflow isolation and four-slot checks passed")
PY

echo "ACI quota recovery tests passed"
