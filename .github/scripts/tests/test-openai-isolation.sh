#!/bin/bash

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

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-openai-isolation-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
FIXTURE="$TEST_ROOT/repo with spaces"
mkdir -p "$FIXTURE/.github/scripts"
cp "$REPO_ROOT/.github/scripts/"{generate-recipe-pack,list-recipe-folders,lib-recipe-platform-filter,test-all-recipes}.sh \
    "$FIXTURE/.github/scripts/"
for recipe in AI/models/azure AI/models/kubernetes Data/unrelated/azure \
    Compute/containers/azure Compute/containers/kubernetes \
    Security/secrets/azure Security/secrets/kubernetes; do
    type="${recipe%/*}" platform="${recipe##*/}"
    mkdir -p "$FIXTURE/$type/recipes/$platform/bicep"
    touch "$FIXTURE/$type/recipes/$platform/bicep/main.bicep"
done
mkdir -p "$FIXTURE/Data/unrelated/recipes/azure/terraform"
touch "$FIXTURE/Data/unrelated/recipes/azure/terraform/main.tf"
export CALL_LOG="$TEST_ROOT/calls"
cat >"$FIXTURE/.github/scripts/test-recipe.sh" <<'EOF'
#!/bin/bash
echo "$1" >>"$CALL_LOG"
exit "${TEST_EXIT_CODE:-0}"
EOF
chmod +x "$FIXTURE/.github/scripts/"*.sh

fail() { echo "FAIL: $*" >&2; exit 1; }

discover() {
    RTC_OPENAI_TEST_SCOPE="$1" RECIPE_PLATFORM_FILTER=azure \
        bash "$FIXTURE/.github/scripts/list-recipe-folders.sh" "$FIXTURE" "${2:-bicep}"
}

for scope in all only exclude; do
    discover "$scope" >"$TEST_ROOT/selected"
    if [[ "$scope" == only ]]; then
        [[ "$(cat "$TEST_ROOT/selected")" == "$FIXTURE/AI/models/recipes/azure/bicep" ]] ||
            fail "OpenAI-only discovery must select just the Azure model recipe"
    else
        grep -Fq '/Data/unrelated/recipes/azure/bicep' "$TEST_ROOT/selected" ||
            fail "$scope must retain unrelated Azure recipes"
        if [[ "$scope" == all ]]; then
            grep -Fq '/AI/models/recipes/azure/bicep' "$TEST_ROOT/selected" ||
                fail "default scope must retain OpenAI"
        elif grep -Fq '/AI/models/' "$TEST_ROOT/selected"; then
            fail "general discovery must exclude OpenAI"
        fi
    fi
done
[[ "$(discover exclude terraform)" == "$FIXTURE/Data/unrelated/recipes/azure/terraform" ]] ||
    fail "OpenAI exclusion must retain Terraform recipes"
RTC_OPENAI_TEST_SCOPE=exclude RECIPE_PLATFORM_FILTER=kubernetes \
    bash "$FIXTURE/.github/scripts/list-recipe-folders.sh" "$FIXTURE" bicep >"$TEST_ROOT/selected"
grep -Fq '/AI/models/recipes/kubernetes/bicep' "$TEST_ROOT/selected" ||
    fail "Azure OpenAI exclusion must not suppress non-Azure models"
if discover invalid >"$TEST_ROOT/error" 2>&1; then fail "invalid scope must fail discovery"; fi
grep -q 'RTC_OPENAI_TEST_SCOPE must be' "$TEST_ROOT/error" || fail "invalid scope needs an explicit error"

PACK="$TEST_ROOT/pack.bicep"
for scope in only exclude; do
    RTC_OPENAI_TEST_SCOPE="$scope" RTC_ACI_TEST_SCOPE=exclude RECIPE_PLATFORM_FILTER=azure \
        bash "$FIXTURE/.github/scripts/generate-recipe-pack.sh" "$FIXTURE" basic "$PACK" >/dev/null
    if [[ "$scope" == only ]]; then
        [[ "$(grep -c "^      'Radius\\." "$PACK")" == 3 ]] ||
            fail "OpenAI pack must contain exactly the model and its two dependencies"
        grep -q "'Radius.AI/models':" "$PACK" || fail "OpenAI pack lost models"
    elif grep -q "'Radius.AI/models':" "$PACK"; then
        fail "general pack must exclude OpenAI"
    fi
    for dependency in Compute/containers Security/secrets; do
        [[ "$(grep -Fc "'Radius.$dependency':" "$PACK")" == 1 ]] ||
            fail "$scope needs exactly one $dependency entry"
        grep -A4 "'Radius.$dependency':" "$PACK" | grep -q '/kubernetes/bicep/main:latest' ||
            fail "$scope must use Kubernetes $dependency, not Azure"
    done
    : >"$CALL_LOG"
    (
        cd "$FIXTURE"
        RTC_OPENAI_TEST_SCOPE="$scope" RTC_ACI_TEST_SCOPE=exclude RECIPE_PLATFORM_FILTER=azure \
            bash .github/scripts/test-all-recipes.sh "$FIXTURE" default bicep >/dev/null
    ) || fail "$scope per-recipe runner"
    if [[ "$scope" == only ]]; then
        [[ "$(cat "$CALL_LOG")" == "$FIXTURE/AI/models/recipes/azure/bicep" ]] ||
            fail "dedicated runner must test only the model, not its dependencies"
    else
        [[ "$(wc -l <"$CALL_LOG")" == 2 ]] || fail "general runner lost unrelated recipes"
        ! grep -q '/AI/models/' "$CALL_LOG" || fail "general runner must not deploy OpenAI"
    fi
done
if (
    cd "$FIXTURE"
    RTC_OPENAI_TEST_SCOPE=only RECIPE_PLATFORM_FILTER=azure TEST_EXIT_CODE=1 \
        bash .github/scripts/test-all-recipes.sh "$FIXTURE" default bicep >/dev/null
); then fail "OpenAI recipe failures must propagate"; fi
mkdir -p "$TEST_ROOT/empty"
if RTC_OPENAI_TEST_SCOPE=only bash "$FIXTURE/.github/scripts/test-all-recipes.sh" \
    "$TEST_ROOT/empty" default bicep >"$TEST_ROOT/error" 2>&1; then
    fail "empty OpenAI scope must fail testing"
fi
grep -q 'Error: no OpenAI recipes found to test.' "$TEST_ROOT/error" ||
    fail "empty OpenAI scope needs an explicit error"

python3 - "$REPO_ROOT" <<'PY'
import os
import pathlib
import re
import subprocess
import sys
import textwrap

workflows = pathlib.Path(sys.argv[1]) / ".github/workflows"
for filename, job in (
    ("validate-azure-recipes", "validate-azure-recipes"),
    ("nightly-recipe-pack-tests", "nightly-azure-recipe-pack-tests"),
    ("release-candidate-recipe-pack-tests", "rc-azure-recipe-pack-tests"),
):
    source = (workflows / f"{filename}.yaml").read_text()
    body = re.search(rf"^  {job}:\n(.*?)(?=^  [\w-]+:|\Z)", source, re.M | re.S).group(1)
    assert "RTC_OPENAI_TEST_SCOPE: exclude" in body, filename
    assert "test-azure-openai.yaml" not in body, filename

worker = (workflows / "test-azure-openai.yaml").read_text()
assert "group: azure-openai-test-capacity\n" in worker
assert "cancel-in-progress: false\n      queue: max" in worker
assert "RTC_OPENAI_TEST_SCOPE: only" in worker
assert "RTC_ACI_TEST_SCOPE: exclude" in worker
assert "make build-azure-recipes" in worker
assert 'RECIPE_PLATFORM_FILTER=azure make test' in worker
assert "RECIPE_PACK_USE_LOCAL_RECIPES: ${{ !inputs.release_candidate && 'true' || 'false' }}" in worker
for step_name in ("Test checked-in OpenAI Recipe Pack entry", "Test generated OpenAI Bicep recipe"):
    step = worker.split(f"- name: {step_name}", 1)[1].split("- name:", 1)[0]
    assert "continue-on-error:" not in step
    assert "RTC_AZURE_TEST_STEP_DEADLINE_EPOCH" in step
assert re.search(r"name: Release OpenAI capacity.*?if: always\(\).*?run: make cleanup-azure-resources",
                 worker, re.S)
assert "cleanup-openai-resources:" in worker
fallback = worker.split("  cleanup-openai-resources:", 1)[1]
assert "inputs.checkout_ref" not in fallback
assert "if: always()" in fallback

ci = (workflows / "validate-azure-openai-recipes.yaml").read_text()
assert "pull_request_target:" in ci and "merge_group:" in ci
assert "environment: azure" in ci
assert "needs.check-trust.result == 'success'" in ci
assert "needs.approval-gate.result == 'success'" in ci
assert "needs.check-trust.outputs.is-external == 'false'" in ci
assert "checkout_ref: ${{ github.event.pull_request.head.sha || github.sha }}" in ci
assert "uses: ./.github/workflows/test-azure-openai.yaml" in ci
result_job = ci.split("  openai-validation-result:", 1)[1]
assert "if: always()" in result_job
command = textwrap.dedent(result_job.split("        run: |\n", 1)[1])
for path_result in ("success", "failure", "cancelled", "skipped"):
    for changed in ("true", "false", "", "invalid"):
        for test_result in ("success", "failure", "cancelled", "skipped"):
            result = subprocess.run(
                ["bash", "-c", command], capture_output=True, text=True,
                env={**os.environ, "PATH_RESULT": path_result,
                     "OPENAI_CHANGED": changed, "TEST_RESULT": test_result})
            should_pass = path_result == "success" and (
                changed == "false" or changed == "true" and test_result == "success")
            assert (result.returncode == 0) == should_pass, (
                path_result, changed, test_result, result.stdout, result.stderr)

for filename in ("nightly-azure-openai-tests", "release-candidate-recipe-pack-tests"):
    source = (workflows / f"{filename}.yaml").read_text()
    assert "uses: ./.github/workflows/test-azure-openai.yaml" in source, filename
    assert "test_checked_in_pack: true" in source, filename
assert "release_candidate: true" in (workflows / "release-candidate-recipe-pack-tests.yaml").read_text()
PY

echo "OpenAI isolation tests passed"
