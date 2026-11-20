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
mkdir -p "$TEST_ROOT/bin"
export PATH="$TEST_ROOT/bin:$PATH" CALL_LOG="$TEST_ROOT/calls"
export CLOUD_LOG="$TEST_ROOT/cloud" GROUP_STATE="$TEST_ROOT/group.json"
export GITHUB_ACTIONS=true GITHUB_REPOSITORY=radius-project/resource-types-contrib
export GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=2 AZURE_LOCATION=westus3
export AZURE_SUBSCRIPTION_ID=11111111-2222-3333-4444-555555555555
export AZURE_RESOURCE_GROUP=rrttest-123-2-openai RTC_PURGE_OPENAI_ACCOUNTS=true
GROUP_ID="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP"
export GROUP_JSON
GROUP_JSON="$(jq -cn --arg id "$GROUP_ID" '{id:$id,tags:{
    rtcRepository:"radius-project/resource-types-contrib",rtcRunId:"123",
    rtcRunAttempt:"2",rtcPurpose:"azure-openai-test"}}')"
export ACTIVE_JSON DELETED_JSON
ACTIVE_JSON="$(jq -cn --arg id "$GROUP_ID/providers/Microsoft.CognitiveServices/accounts/live" \
    '[{id:$id,name:"live",kind:"OpenAI",location:"westus3"}]')"
DELETED_JSON="$(jq -cn --arg prefix "/subscriptions/$AZURE_SUBSCRIPTION_ID/providers/Microsoft.CognitiveServices/locations/westus3/resourceGroups/" \
    --arg group "$AZURE_RESOURCE_GROUP" '[
    {id:($prefix+$group+"/deletedAccounts/soft"),name:"soft",kind:"OpenAI",location:"westus3"},
    {id:($prefix+"unrelated/deletedAccounts/other"),name:"other",kind:"OpenAI",location:"westus3"},
    {id:("/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/providers/Microsoft.CognitiveServices/locations/westus3/resourceGroups/"+$group+"/deletedAccounts/foreign"),name:"foreign",kind:"OpenAI",location:"westus3"},
    {id:($prefix+$group+"-other/deletedAccounts/lookalike"),name:"lookalike",kind:"OpenAI",location:"westus3"},
    {id:($prefix+$group+"/deletedAccounts/speech"),name:"speech",kind:"SpeechServices",location:"westus3"}
]')"

cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "az $*" >>"$CALL_LOG"
echo "az $*" >>"$CLOUD_LOG"
case "$1 $2 $3" in
    "group exists "*)
        if [[ "${EXISTS_FAIL:-0}" == 1 ]]; then exit 1; fi
        if grep -q '^az group delete ' "$CLOUD_LOG"; then
            echo "${EXISTS_AFTER:-false}"
        else echo "${GROUP_EXISTS:-true}"; fi ;;
    "group show "*)
        [[ "${OWNERSHIP_FAIL:-0}" == 0 ]] || exit 1
        cat "$GROUP_STATE" ;;
    "tag update "*)
        [[ "${TAG_FAIL:-0}" == 0 ]] || exit 1
        while [[ "$1" != --tags ]]; do shift; done
        state="${2#rtcOpenaiCleanup=}"
        group="$(jq -c --arg state "$state" '.tags.rtcOpenaiCleanup = $state' "$GROUP_STATE")"
        echo "$group" >"$GROUP_STATE"
        jq '{properties:{tags:.tags}}' <<<"$group" ;;
    "group delete "*) exit "${GROUP_DELETE_FAIL:-0}" ;;
    "group create "*) exit "${GROUP_CREATE_FAIL:-0}" ;;
    "deployment group list")
        [[ "${DEPLOYMENT_LIST_FAIL:-0}" == 0 ]] || exit 1
        echo "${DEPLOYMENTS_JSON:-[]}" ;;
    "resource list "*)
        [[ "${RESOURCE_LIST_FAIL:-0}" == 0 ]] || exit 1
        echo "${RESOURCES_JSON:-[]}" ;;
    "cognitiveservices account list")
        [[ "${ACTIVE_FAIL:-0}" == 0 ]] || exit 1
        if [[ "${NO_ACTIVE_BEFORE_DEPLOY:-0}" == 1 ]] && ! grep -q '^rad deploy ' "$CLOUD_LOG"; then
            echo '[]'
        elif grep -Eq '^(az cognitiveservices account delete|rad app delete) ' "$CLOUD_LOG" && [[ "${ACTIVE_STUCK:-0}" == 0 ]]; then
            echo '[]'
        else echo "$ACTIVE_JSON"; fi ;;
    "cognitiveservices account list-deleted")
        [[ "${DELETED_FAIL:-0}" == 0 ]] || exit 1
        data="$DELETED_JSON"
        if [[ "${DELAY_DELETED:-0}" == 1 && "$(grep -c '^az cognitiveservices account list-deleted ' "$CLOUD_LOG")" == 1 ]]; then
            data='[]'
        fi
        if grep -Eq '^(az cognitiveservices account delete|rad app delete) ' "$CLOUD_LOG" && [[ "${TOMBSTONE_MISSING:-0}" == 0 ]]; then
            data="$(jq -cn --argjson deleted "$data" --argjson active "$ACTIVE_JSON" '$deleted + $active')"
        fi
        if [[ "${PURGE_STUCK:-0}" == 0 ]]; then
            while read -r name; do data="$(jq -c --arg name "$name" 'map(select(.name != $name))' <<<"$data")"; done \
                < <(sed -n 's/^az cognitiveservices account purge --name \([^ ]*\).*/\1/p' "$CLOUD_LOG")
        fi
        echo "$data" ;;
    "cognitiveservices account delete") exit "${DELETE_FAIL:-0}" ;;
    "cognitiveservices account purge") exit "${PURGE_FAIL:-0}" ;;
    "cognitiveservices usage list")
        [[ "${USAGE_FAIL:-0}" == 0 ]] || exit 1
        if [[ -n "${USAGE_JSON:-}" ]]; then echo "$USAGE_JSON"; exit; fi
        value="${QUOTA_START:-30}"
        if [[ "${NO_ACTIVE_BEFORE_DEPLOY:-0}" == 1 ]] && grep -q '^rad deploy ' "$CLOUD_LOG"; then
            value=$((value + 1))
        fi
        purges="$(grep -c '^az cognitiveservices account purge ' "$CLOUD_LOG" || true)"
        if [[ "${QUOTA_STUCK:-0}" == 0 ]]; then value=$((value - purges)); fi
        printf '[{"name":{"value":"OpenAI.S0.AccountCount"},"currentValue":%s,"limit":30}]\n' "$value" ;;
    *) echo "Unexpected az command: $*" >&2; exit 1 ;;
esac
EOF
cat >"$TEST_ROOT/bin/timeout" <<'EOF'
#!/bin/bash
echo "timeout $*" >>"$CALL_LOG"
if [[ "$2" == 6m ]]; then
    shift 2
    exec /usr/bin/timeout --kill-after=1s "${HELPER_TIMEOUT:-12s}" "$@"
fi
exec /usr/bin/timeout "$@"
EOF
cat >"$TEST_ROOT/bin/sleep" <<'EOF'
#!/bin/bash
/usr/bin/sleep 0.02
EOF
chmod +x "$TEST_ROOT/bin/"*

fail() { echo "FAIL: $*" >&2; cat "$TEST_ROOT/output" >&2; exit 1; }
reset_test() {
    : >"$CLOUD_LOG"
    echo "$GROUP_JSON" >"$GROUP_STATE"
}
invoke_cleanup() {
    : >"$CALL_LOG"
    bash "$REPO_ROOT/.github/scripts/cleanup-azure-resources.sh" >"$TEST_ROOT/output" 2>&1
}
run_test() {
    reset_test
    invoke_cleanup
}
no_mutation() {
    if grep -Eq '^az (group delete|cognitiveservices account (delete|purge)) ' "$CALL_LOG"; then
        fail "unverified ownership must prevent mutation"
    fi
}

run_test || fail "active and soft-deleted cleanup"
[[ "$(grep -c '^az cognitiveservices account purge ' "$CALL_LOG")" == 2 ]] || fail "purge both owned accounts"
grep -q 'account purge --name soft --resource-group rrttest-123-2-openai --location westus3 --subscription' "$CALL_LOG" ||
    fail "purge must use the exact group, region, and subscription"
if grep -Eq 'account purge --name (other|foreign|lookalike|speech)' "$CALL_LOG"; then fail "unrelated purge"; fi
awk '/^az cognitiveservices account purge / { purges++ }
    /^az cognitiveservices usage list / { if (purges == 2) verified=1 }
    /^az group delete / { if (!verified) exit 1; deleted=1 }
    END { if (!deleted) exit 1 }' "$CALL_LOG" || fail "group deletion must follow purge and quota verification"
[[ "$(grep -c '^az group exists ' "$CALL_LOG")" == 2 ]] || fail "confirm resource-group deletion"
grep -q '^timeout --kill-after=5s 6m bash ' "$CALL_LOG" || fail "bound the whole purge operation"

# Azure has returned both original account IDs and deletedAccounts locators.
original="$(jq -c --arg prefix "$GROUP_ID/providers/Microsoft.CognitiveServices/accounts/" \
    '.[0:1] | map(.id = ($prefix + .name))' <<<"$DELETED_JSON")"
DELETED_JSON="$original" run_test || fail "original account ID tombstones"

for field in rtcRepository rtcRunId rtcRunAttempt rtcPurpose; do
    bad_group="$(jq -c --arg field "$field" '.tags[$field] = "unrelated"' <<<"$GROUP_JSON")"
    if GROUP_JSON="$bad_group" run_test; then fail "mismatched $field"; fi
    no_mutation
done
bad_group="$(jq -c '.id += "-other"' <<<"$GROUP_JSON")"
if GROUP_JSON="$bad_group" run_test; then fail "mismatched group ID"; fi
no_mutation
if GROUP_JSON='{}' run_test; then fail "missing ownership tags"; fi
no_mutation
if GITHUB_REPOSITORY=other/repo run_test; then fail "wrong repository"; fi
no_mutation
if GITHUB_RUN_ATTEMPT=3 run_test; then fail "wrong attempt"; fi
no_mutation
if GITHUB_ACTIONS=false run_test; then fail "local invocation"; fi
no_mutation
if AZURE_RESOURCE_GROUP='' run_test; then fail "missing cleanup group"; fi
no_mutation
if RTC_PURGE_OPENAI_ACCOUNTS=invalid run_test; then fail "invalid purge control"; fi
no_mutation

for control in OWNERSHIP_FAIL ACTIVE_FAIL DELETED_FAIL USAGE_FAIL TAG_FAIL; do
    if (export "$control=1"; run_test); then fail "$control"; fi
    no_mutation
done
for bad in '{}' null '[{}]' '[{"id":"/unexpected","kind":"OpenAI"}]'; do
    if DELETED_JSON="$bad" run_test; then fail "malformed deleted inventory"; fi
    no_mutation
done
bad_active="$(jq -c 'map(.id |= sub("rrttest-123-2-openai"; "other"))' <<<"$ACTIVE_JSON")"
if ACTIVE_JSON="$bad_active" run_test; then fail "active account outside the resource group"; fi
no_mutation
for expression in '.name = "wrong"' '.location = "eastus"' '.id += "/child"'; do
    bad="$(jq -c --argjson account "$(jq -c '.[0]' <<<"$DELETED_JSON")" \
        -n "\$account | $expression | [.]")"
    if DELETED_JSON="$bad" run_test; then fail "invalid deleted account $expression"; fi
    no_mutation
done
for bad in '[]' '{}' '[{"name":{"value":"OpenAI.S0.AccountCount"},"currentValue":"30","limit":30}]'; do
    if USAGE_JSON="$bad" run_test; then fail "invalid quota inventory"; fi
    no_mutation
done

for control in DELETE_FAIL PURGE_FAIL; do
    for status in 1 124; do
        if (export "$control=$status"; run_test); then fail "$control=$status"; fi
        if grep -q '^az group delete ' "$CALL_LOG"; then fail "retain group after $control"; fi
    done
done
for control in ACTIVE_STUCK PURGE_STUCK TOMBSTONE_MISSING QUOTA_STUCK; do
    if (export "$control=1" HELPER_TIMEOUT=2s; run_test); then fail "$control must time out"; fi
    if grep -q '^az group delete ' "$CALL_LOG"; then fail "retain group after $control"; fi
    grep -q 'cleanup failed or timed out' "$TEST_ROOT/output" || fail "explicit timeout report"
done
if GROUP_DELETE_FAIL=1 run_test; then fail "group deletion error"; fi
if EXISTS_AFTER=true run_test; then fail "group deletion not confirmed"; fi

if GROUP_EXISTS=false run_test; then fail "absent group with deleted accounts requires operator review"; fi
no_mutation
grep -q 'ownership evidence is absent' "$TEST_ROOT/output" || fail "explain missing ownership"
empty_quota='[{"name":{"value":"OpenAI.S0.AccountCount"},"currentValue":28,"limit":30}]'
GROUP_EXISTS=false DELETED_JSON='[]' USAGE_JSON="$empty_quota" run_test || fail "idempotent absent group"
no_mutation
ACTIVE_JSON='[]' DELETED_JSON='[]' USAGE_JSON="$empty_quota" run_test || fail "idempotent empty group"
ACTIVE_JSON='[]' DELETED_JSON='[]' USAGE_FAIL=1 run_test ||
    fail "empty run must not depend on unrelated regional quota"
if grep -q '^az cognitiveservices usage list ' "$CALL_LOG"; then fail "empty run must skip quota"; fi
grep -q '^az group delete ' "$CALL_LOG" || fail "delete an empty group at full regional quota"
RTC_PURGE_OPENAI_ACCOUNTS=false run_test || fail "ordinary Azure cleanup unchanged"
if grep -q '^az cognitiveservices ' "$CALL_LOG"; then fail "purge is opt-in"; fi

# A fallback must keep the original target after the accounts have been purged.
reset_test
if DELETED_JSON='[]' QUOTA_START=29 QUOTA_STUCK=1 HELPER_TIMEOUT=2s invoke_cleanup; then
    fail "first invocation must retain the group while usage is 29, not 28"
fi
jq -e '.tags.rtcOpenaiCleanup | fromjson | .target == 28 and .accounts.live == true' "$GROUP_STATE" >/dev/null ||
    fail "save the original target and completed purge"
if DELETED_JSON='[]' QUOTA_START=29 QUOTA_STUCK=1 HELPER_TIMEOUT=2s invoke_cleanup; then
    fail "fallback must not raise the target to 29"
fi
if grep -q '^az group delete ' "$CALL_LOG"; then fail "fallback deleted the group before quota recovery"; fi
DELETED_JSON='[]' QUOTA_START=28 QUOTA_STUCK=1 invoke_cleanup || fail "fallback must finish once usage reaches 28"

# A recorded account can be absent from both lists while Azure publishes its tombstone.
recorded="$(jq -c '.tags.rtcOpenaiCleanup = "{\"target\":28,\"accounts\":{\"soft\":false},\"recording\":false}"' <<<"$GROUP_JSON")"
ACTIVE_JSON='[]' GROUP_JSON="$recorded" DELAY_DELETED=1 QUOTA_START=29 run_test ||
    fail "wait for the known deleted account when the initial inventory is empty"
grep -q '^az cognitiveservices account purge --name soft ' "$CALL_LOG" || fail "known delayed account was not purged"

# Successful release is a quota receipt, not a reservation against the next worker.
reset_test
invoke_cleanup || fail "initial successful capacity release"
RTC_OPENAI_RELEASE_CONFIRMED=true USAGE_JSON='[{"name":{"value":"OpenAI.S0.AccountCount"},"currentValue":30,"limit":30}]' \
    invoke_cleanup || fail "fallback must allow capacity to be reused after a successful release"
if grep -q '^az cognitiveservices usage list ' "$CALL_LOG"; then fail "confirmed release must not recheck quota"; fi
no_mutation
if GROUP_EXISTS=false RTC_OPENAI_RELEASE_CONFIRMED=true run_test; then fail "confirmed release still requires deleted-account absence"; fi
no_mutation
if RTC_OPENAI_RELEASE_CONFIRMED=true run_test; then fail "confirmed release still requires group absence"; fi
no_mutation

# The deployed identity and pre-deploy quota baseline must survive app teardown.
cat >"$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
echo "rad $*" >>"$CALL_LOG"
echo "rad $*" >>"$CLOUD_LOG"
if [[ "$1" == deploy && "${DEPLOY_FAIL:-0}" == 1 ]]; then
    echo '{"error":{"code":"InsufficientQuota","message":"Account quota is exhausted"}}' >&2
    exit 1
fi
EOF
chmod +x "$TEST_ROOT/bin/rad"
printf 'param applicationName string\n' >"$TEST_ROOT/app.bicep"
reset_test
: >"$CALL_LOG"
record_deployment() {
    bash "$REPO_ROOT/.github/scripts/cleanup-openai-accounts.sh" true begin || return 1
    local TAG_FAIL="${1:-0}"
    export TAG_FAIL
    # shellcheck source=.github/scripts/lib-recipe-test.sh
    source "$REPO_ROOT/.github/scripts/lib-recipe-test.sh"
    rtc_deploy_and_assert_test_app "$TEST_ROOT/app.bicep" Radius.AI/models openai /env default ""
}
NO_ACTIVE_BEFORE_DEPLOY=1 DELETED_JSON='[]' QUOTA_START=28 record_deployment \
    >"$TEST_ROOT/output" 2>&1 || fail "record deployed identity before app deletion"
jq -e '.tags.rtcOpenaiCleanup | fromjson | .target == 28 and .accounts.live == false and .recording == false' \
    "$GROUP_STATE" >/dev/null || fail "deployed account identity and quota target must be durable"
awk '/^az tag update .*accounts.*live/ { recorded=1 }
    /^rad app delete / { if (!recorded) exit 1; deleted=1 }
    END { if (!deleted) exit 1 }' "$CALL_LOG" || fail "save account identity before test teardown"
reset_test
if NO_ACTIVE_BEFORE_DEPLOY=1 DELETED_JSON='[]' QUOTA_START=28 TAG_FAIL=1 \
    bash "$REPO_ROOT/.github/scripts/cleanup-openai-accounts.sh" true begin >"$TEST_ROOT/output" 2>&1; then
    fail "failed baseline persistence must block deployment"
fi
reset_test
: >"$CALL_LOG"
if NO_ACTIVE_BEFORE_DEPLOY=1 DELETED_JSON='[]' QUOTA_START=28 record_deployment 1 \
    >"$TEST_ROOT/output" 2>&1; then fail "failed identity persistence must block app deletion"; fi
if grep -q '^rad app delete ' "$CALL_LOG"; then fail "do not erase an unrecorded identity"; fi

# A quota-rejected deployment can finish without ever creating an account.
pending="$(jq -c '.tags.rtcOpenaiCleanup = "{\"target\":30,\"accounts\":{},\"recording\":true}"' <<<"$GROUP_JSON")"
reset_test
: >"$CALL_LOG"
if ACTIVE_JSON='[]' DELETED_JSON='[]' QUOTA_START=30 DEPLOY_FAIL=1 record_deployment \
    >"$TEST_ROOT/output" 2>&1; then fail "quota-rejected test must still fail"; fi
grep -q '^rad app delete ' "$CALL_LOG" || fail "empty failed deployment must allow app teardown"
jq -e '.tags.rtcOpenaiCleanup | fromjson | .recording == false and .accounts == {}' \
    "$GROUP_STATE" >/dev/null || fail "record empty failure before app teardown"
ACTIVE_JSON='[]' DELETED_JSON='[]' QUOTA_START=30 invoke_cleanup ||
    fail "clean up quota-rejected run without claiming available capacity"
reset_test
echo "$pending" >"$GROUP_STATE"
ACTIVE_JSON='[]' DELETED_JSON='[]' QUOTA_START=30 \
    bash "$REPO_ROOT/.github/scripts/cleanup-openai-accounts.sh" true record \
    >"$TEST_ROOT/output" 2>&1 || fail "record a settled empty deployment at full quota"
jq -e '.tags.rtcOpenaiCleanup | fromjson | .recording == false and .accounts == {}' \
    "$GROUP_STATE" >/dev/null || fail "persist empty completion before app teardown"
ACTIVE_JSON='[]' DELETED_JSON='[]' USAGE_FAIL=1 invoke_cleanup ||
    fail "recorded empty run must clean up without a quota read"
if grep -q '^az cognitiveservices usage list ' "$CALL_LOG"; then fail "recorded empty cleanup rechecked quota"; fi
ACTIVE_JSON='[]' DELETED_JSON='[]' GROUP_JSON="$pending" QUOTA_START=30 run_test ||
    fail "fallback must settle and remove an empty run at full quota"
terminal_resource="$(jq -cn --arg id "$GROUP_ID/providers/Microsoft.Storage/storageAccounts/test" \
    '[{id:$id,provisioningState:"Succeeded"}]')"
ACTIVE_JSON='[]' DELETED_JSON='[]' GROUP_JSON="$pending" RESOURCES_JSON="$terminal_resource" \
    DEPLOYMENTS_JSON='[{"properties":{"provisioningState":"Failed"}}]' run_test ||
    fail "terminal failed deployment and unrelated completed resource allow empty cleanup"

for status in Accepted Running Creating Updating Deleting; do
    deployments="$(jq -cn --arg status "$status" '[{properties:{provisioningState:$status}}]')"
    if ACTIVE_JSON='[]' DELETED_JSON='[]' GROUP_JSON="$pending" DEPLOYMENTS_JSON="$deployments" \
        HELPER_TIMEOUT=2s run_test; then fail "retain empty run with $status deployment"; fi
    no_mutation
done
hidden_account="$(jq -cn --arg id "$GROUP_ID/providers/Microsoft.CognitiveServices/accounts/hidden" \
    '[{id:$id,provisioningState:"Succeeded"}]')"
if ACTIVE_JSON='[]' DELETED_JSON='[]' GROUP_JSON="$pending" RESOURCES_JSON="$hidden_account" \
    HELPER_TIMEOUT=2s run_test; then fail "generic inventory account must prevent empty completion"; fi
no_mutation
resources="$(jq -cn --arg id "$GROUP_ID/providers/Microsoft.Storage/storageAccounts/test" \
    '[{id:$id,properties:{provisioningState:"Updating"}}]')"
if ACTIVE_JSON='[]' DELETED_JSON='[]' GROUP_JSON="$pending" RESOURCES_JSON="$resources" \
    HELPER_TIMEOUT=2s run_test; then fail "retain empty run with an updating resource"; fi
no_mutation
for control in DEPLOYMENT_LIST_FAIL RESOURCE_LIST_FAIL USAGE_FAIL; do
    if (export "$control=1"; ACTIVE_JSON='[]' DELETED_JSON='[]' GROUP_JSON="$pending" run_test); then
        fail "empty completion must fail closed for $control"
    fi
    no_mutation
done
for bad in '{}' '[{}]'; do
    if ACTIVE_JSON='[]' DELETED_JSON='[]' GROUP_JSON="$pending" DEPLOYMENTS_JSON="$bad" \
        HELPER_TIMEOUT=2s run_test; then fail "unknown deployment states cannot prove empty completion"; fi
    no_mutation
    if ACTIVE_JSON='[]' DELETED_JSON='[]' GROUP_JSON="$pending" RESOURCES_JSON="$bad" \
        HELPER_TIMEOUT=2s run_test; then fail "unknown resource states cannot prove empty completion"; fi
    no_mutation
done
lower_baseline="$(jq -c '.tags.rtcOpenaiCleanup = "{\"target\":29,\"accounts\":{},\"recording\":true}"' <<<"$GROUP_JSON")"
if ACTIVE_JSON='[]' DELETED_JSON='[]' GROUP_JSON="$lower_baseline" QUOTA_START=30 \
    HELPER_TIMEOUT=2s run_test; then fail "empty inventory with elevated usage is not settled"; fi
no_mutation

reset_test
python3 - "$REPO_ROOT" <<'PY'
import os
import pathlib
import subprocess
import sys
import tempfile
import textwrap

workflow = (pathlib.Path(sys.argv[1]) / ".github/workflows/test-azure-openai.yaml").read_text()
step = workflow.split("- name: Create Azure Resource Group", 1)[1].split("- name:", 1)[0]
command = textwrap.dedent(step.split("        run: |\n", 1)[1])
guard = workflow.split("- name: Require the CI repository before provisioning", 1)[1].split("- name:", 1)[0]
guard = textwrap.dedent(guard.split("        run: |\n", 1)[1])
log = pathlib.Path(os.environ["CALL_LOG"])
for exists, read_fail, create_fail in (
    ("false", "0", "0"), ("true", "0", "0"), ("unknown", "0", "0"),
    ("false", "1", "0"), ("false", "0", "1"),
):
    log.write_text("")
    result = subprocess.run(
        ["bash", "-c", command], capture_output=True, text=True,
        env={**os.environ, "GROUP_EXISTS": exists, "EXISTS_FAIL": read_fail,
             "GROUP_CREATE_FAIL": create_fail},
    )
    allowed = exists == "false" and read_fail == "0"
    assert (result.returncode == 0) == (allowed and create_fail == "0"), result.stderr
    calls = log.read_text()
    assert ("az group create " in calls) == allowed, calls
    if allowed:
        for tag in ("rtcRepository=radius-project/resource-types-contrib", "rtcRunId=123",
                    "rtcRunAttempt=2", "rtcPurpose=azure-openai-test"):
            assert tag in calls, calls
log.write_text("")
result = subprocess.run(
    ["bash", "-c", guard + "\n" + command], capture_output=True, text=True,
    env={**os.environ, "GITHUB_REPOSITORY": "copy/resource-types-contrib", "GROUP_EXISTS": "false"},
)
assert result.returncode != 0 and not log.read_text(), "repository copy must fail before Azure provisioning"

cleanup = workflow.split("- name: Release OpenAI capacity before leaving the slot", 1)[1].split(
    "\n  cleanup-openai-resources:", 1)[0].split("        run: ", 1)[1].strip()
with tempfile.TemporaryDirectory(prefix="rtc-approved-head-") as directory:
    checkout = pathlib.Path(directory)
    old_wrapper = checkout / ".github/scripts/cleanup-azure-resources.sh"
    old_wrapper.parent.mkdir(parents=True)
    old_wrapper.write_text('#!/bin/bash\necho old-wrapper >>"$CALL_LOG"\naz group delete --name "$AZURE_RESOURCE_GROUP" --yes\n')
    recipe = checkout / "AI/models/test/app.bicep"
    recipe.parent.mkdir(parents=True)
    recipe.write_text("// approved PR head recipe\n")
    log.write_text("")
    pathlib.Path(os.environ["CLOUD_LOG"]).write_text("")
    result = subprocess.run(
        ["bash", "-c", cleanup], cwd=checkout, capture_output=True, text=True,
        env={**os.environ, "RTC_OPENAI_SCRIPTS_DIR": str(pathlib.Path(sys.argv[1]) / ".github/scripts")},
    )
    assert result.returncode == 0, (result.stdout, result.stderr)
    calls = log.read_text()
    assert "old-wrapper" not in calls and "account purge --name soft" in calls, calls
    assert recipe.read_text() == "// approved PR head recipe\n", "keep approved recipe sources intact"
PY

echo "OpenAI cleanup tests passed"
