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
PROBE="$REPO_ROOT/.github/scripts/probe-azure-postgres-capacity.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-postgres-probe-test-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
export CALL_LOG="$TEST_ROOT/calls"
export CREATE_RESULTS="$TEST_ROOT/create-results"
export SERVER_STATE="$TEST_ROOT/server"
export RTC_POSTGRES_PROBE_RESULT_FILE="$TEST_ROOT/result.json"
REAL_TIMEOUT="$(command -v timeout)"
export REAL_TIMEOUT
export REAL_PYTHON3
REAL_PYTHON3="$(command -v python3)"
export CATALOG_JSON
CATALOG_JSON="$(jq -cn '{supportedServerVersions:[{name:"16",status:null}],supportedServerEditions:
    [({name:"Burstable",supportedServerSkus:[{name:"Standard_B1ms"}]}),
     ({name:"GeneralPurpose",supportedServerSkus:[{name:"Standard_D2ds_v5"}]})]
    | map(. + {supportedStorageEditions:[{name:"ManagedDisk",supportedStorageMb:[{storageSizeMb:32768}]}]})}
    | [. + {status:null,reason:null,restricted:null,supportedFeatures:[{name:"OfferRestricted",status:"Disabled"}]}]')"

# Track ownership separately from the create result, including partial creates.
cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "$1" == login ]]; then
    [[ "$*" == *'--federated-token test-probe-assertion'* ]] || exit 99
    exit 0
fi
if [[ "$1 ${2:-}" == "account set" ]]; then exit 0; fi
if [[ "$*" == "postgres flexible-server create --help" ]]; then
    echo az-help >>"$CALL_LOG"
    [[ -z "${CLI_HELP_SLEEP:-}" ]] || sleep "$CLI_HELP_SLEEP"
    if [[ -n "${CLI_HELP_RESULT:-}" ]]; then exit "$CLI_HELP_RESULT"; fi
    if [[ -n "${UNSUPPORTED_CLI:-}" ]]; then echo '--other-option'; exit 0; fi
    if [[ -n "${OLD_CLI:-}" ]]; then
        echo '--high-availability --active-directory-auth --password-auth'
    else
        echo '--zonal-resiliency --microsoft-entra-auth --password-auth'
    fi
    exit 0
fi
echo "az $*" >>"$CALL_LOG"
case "$3" in
    list-skus)
        if [[ -n "${CATALOG_INTERRUPTED_STATUS:-}" ]]; then
            echo '(SkuNotAvailable) SKU unavailable.' >&2
            exit "$CATALOG_INTERRUPTED_STATUS"
        fi
        [[ -z "${CATALOG_SLEEP:-}" ]] || sleep "$CATALOG_SLEEP"
        if [[ -n "${CATALOG_FAIL:-}" ]]; then echo '(AuthorizationFailed) Denied' >&2; exit 1; fi
        printf '%s\n' "$CATALOG_JSON"
        exit 0 ;;
    delete)
        if [[ -n "${INTERRUPTED_DELETE_STATUS:-}" ]]; then
            [[ "${DELETE_REMOVES_BEFORE_STATUS:-0}" != 1 ]] || rm -f "$SERVER_STATE"
            echo '(ResourceNotFound) absent' >&2
            exit "$INTERRUPTED_DELETE_STATUS"
        fi
        [[ -z "${DELETE_SLEEP:-}" ]] || sleep "$DELETE_SLEEP"
        if [[ -n "${DELETE_FAILS:-}" ]]; then echo '(Conflict) delete rejected' >&2; exit 1; fi
        if [[ -n "${DELETE_MISSING:-}" ]]; then echo '(ResourceNotFound) absent' >&2; exit 1; fi
        [[ -n "${SERVER_REMAINS:-}" ]] || rm -f "$SERVER_STATE"
        exit 0 ;;
    show)
        if [[ -n "${INTERRUPTED_SHOW_STAGE:-}" ]] && {
            [[ "$INTERRUPTED_SHOW_STAGE" == pre && ! -f "$SERVER_STATE.attempted" ]] ||
            [[ "$INTERRUPTED_SHOW_STAGE" == ownership && -f "$SERVER_STATE" ]] ||
            [[ "$INTERRUPTED_SHOW_STAGE" == deleted && -f "$SERVER_STATE.attempted" && ! -f "$SERVER_STATE" ]]
        }; then
            echo '(ResourceNotFound) absent' >&2
            exit "$INTERRUPTED_STATUS"
        fi
        if [[ -n "${MIXED_SHOW_STAGE:-}" ]] && {
            [[ "$MIXED_SHOW_STAGE" == pre && ! -f "$SERVER_STATE.attempted" ]] ||
            [[ "$MIXED_SHOW_STAGE" == ownership && -f "$SERVER_STATE" ]] ||
            [[ "$MIXED_SHOW_STAGE" == deleted && -f "$SERVER_STATE.attempted" && ! -f "$SERVER_STATE" ]]
        }; then
            if [[ "${MIXED_FORMAT:-plain}" == json ]]; then
                echo '{"error":{"code":"ResourceNotFound","message":"no server","details":[{"message":"Authorization denied."}]}}' >&2
            elif [[ "${MIXED_FORMAT:-plain}" == envelope ]]; then
                printf '%s\n' 'ERROR: (ResourceNotFound) no server' \
                    'Code: ResourceNotFound' 'Message: no server' \
                    'ERROR: (AuthorizationFailed) Denied.' \
                    'Code: AuthorizationFailed' 'Message: Denied.' >&2
            else
                printf '%s\n' 'ERROR: (ResourceNotFound) no server' 'ERROR: Authorization denied.' >&2
            fi
            exit 1
        fi
        if [[ ! -f "$SERVER_STATE.attempted" ]]; then
            [[ -z "${PRECHECK_SLEEP:-}" ]] || sleep "$PRECHECK_SLEEP"
            if [[ -n "${EXISTING_SERVER:-}" ]]; then echo '{"tags":{}}'; exit 0; fi
            if [[ -n "${PRECHECK_ERROR:-}" ]]; then echo "($PRECHECK_ERROR) failed" >&2; exit 1; fi
        fi
        if [[ -f "$SERVER_STATE" ]]; then
            [[ -z "${OWNERSHIP_SLEEP:-}" ]] || sleep "$OWNERSHIP_SLEEP"
            if [[ -n "${OWNERSHIP_ERROR:-}" ]]; then echo "($OWNERSHIP_ERROR) failed" >&2; exit 1; fi
            if [[ -n "${SHOW_ERROR:-}" ]]; then echo "($SHOW_ERROR) failed" >&2; exit 1; fi
            case "${OWNERSHIP:-owned}" in
                foreign) echo '{"tags":{"rtc-probe-owner":"another-owner"}}' ;;
                missing) echo '{"tags":{}}' ;;
                malformed) echo 'not json' ;;
                *) cat "$SERVER_STATE" ;;
            esac
            exit 0
        fi
        if [[ ! -f "$SERVER_STATE.attempted" ]]; then SHOW_ERROR=""; fi
        echo "(${SHOW_ERROR:-ResourceNotFound}) absent" >&2
        if [[ "${MULTILINE_SHOW:-0}" == 1 ]]; then
            printf 'Code: %s\nMessage: %s\n' "${SHOW_ERROR:-ResourceNotFound}" \
                "${MULTILINE_SHOW_MESSAGE:-absent}" >&2
        fi
        exit 1 ;;
esac
touch "$SERVER_STATE.attempted"
if [[ -z "${CREATE_ABSENT:-}" ]]; then
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
        if [[ "${args[i]}" == --tags ]]; then
            owner="${args[i+1]#rtc-probe-owner=}"
            jq -n --arg owner "$owner" '{tags:{"rtc-probe-owner":$owner}}' >"$SERVER_STATE"
        fi
    done
fi
result="$(head -n 1 "$CREATE_RESULTS")"
sed -i '1d' "$CREATE_RESULTS"
case "$result" in
    ok) exit 0 ;;
    capacity) echo '(SkuNotAvailable) SKU unavailable.' >&2 ;;
    busy) echo 'ERROR: (ServerIsBusy) Busy.' >&2 ;;
    multiline-capacity)
        printf '%s\n' 'ERROR: (SkuNotAvailable) SKU unavailable.' \
            'Code: SkuNotAvailable' 'Message: SKU unavailable.' >&2 ;;
    multiline-busy)
        printf '%s\n' 'ERROR: (ServerIsBusy) Busy.' \
            'Code: ServerIsBusy' 'Message: Busy.' >&2 ;;
    multiline-mixed)
        printf '%s\n' 'ERROR: (SkuNotAvailable) SKU unavailable.' \
            'Code: SkuNotAvailable' 'Message: SKU unavailable.' \
            'ERROR: (AuthorizationFailed) Denied.' 'Code: AuthorizationFailed' 'Message: Denied.' >&2 ;;
    multiline-uncoded)
        printf '%s\n' 'ERROR: (SkuNotAvailable) SKU unavailable.' \
            'Code: SkuNotAvailable' 'Message: SKU unavailable.' \
            'ERROR: Access denied.' >&2 ;;
    multiline-inconsistent)
        printf '%s\n' 'ERROR: (SkuNotAvailable) SKU unavailable.' \
            'Code: AuthorizationFailed' 'Message: Access denied.' >&2 ;;
    multiline-contradictory)
        printf '%s\n' 'ERROR: (SkuNotAvailable) SKU unavailable.' \
            'Code: SkuNotAvailable' 'Message: Authorization denied.' >&2 ;;
    multiline-details)
        printf '%s\n' 'ERROR: (SkuNotAvailable) SKU unavailable.' \
            'Code: SkuNotAvailable' 'Message: SKU unavailable.' \
            'Details: An unknown failure occurred.' >&2 ;;
    json) echo '{"error":{"code":"SkuNotAvailable","message":"Unavailable","details":[]}}' >&2 ;;
    mixed) printf '%s\n' '(SkuNotAvailable) Unavailable.' '(AuthorizationFailed) Denied.' >&2 ;;
    uncoded) printf '%s\n' 'ERROR: (SkuNotAvailable) SKU capacity unavailable' \
        'ERROR: The client is not authorized to perform this operation.' >&2 ;;
    uncoded-json) echo '{"error":{"code":"SkuNotAvailable","message":"Unavailable","details":[{"message":"Authorization denied."}]}}' >&2 ;;
    misleading) echo '(AuthorizationFailed) Cannot check SkuNotAvailable.' >&2 ;;
    text) echo 'CLI failed while reading SkuNotAvailable text.' >&2 ;;
    quota) echo '(QuotaExceeded) Quota exceeded.' >&2 ;;
    policy) echo '(RequestDisallowedByPolicy) Policy denied.' >&2 ;;
    leak) echo "(AuthorizationFailed) Request arguments: $*" >&2 ;;
    timeout) exit 124 ;;
    interrupted-int) exit 130 ;;
    interrupted-term) exit 143 ;;
    interrupted-capacity-int) echo '(SkuNotAvailable) SKU unavailable.' >&2; exit 130 ;;
    interrupted-capacity-term) echo '(SkuNotAvailable) SKU unavailable.' >&2; exit 143 ;;
    slow)
        if [[ -n "${CREATE_READY_FILE:-}" ]]; then
            printf '%s\n' "$$" >"$CREATE_READY_FILE"
            sleep 60
        else
            sleep 20
        fi
        exit 0 ;;
    exists)
        echo '{"tags":{"rtc-probe-owner":"another-owner"}}' >"$SERVER_STATE"
        echo '(ServerNameAlreadyExists) Server already exists.' >&2 ;;
    *) echo '(AuthorizationFailed) No authorization.' >&2 ;;
esac
exit 1
EOF

# Keep timeout arguments observable, but use the real timeout implementation.
cat >"$TEST_ROOT/bin/timeout" <<'EOF'
#!/bin/bash
echo "timeout $1 $2" >>"$CALL_LOG"
exec "$REAL_TIMEOUT" "$@"
EOF
cat >"$TEST_ROOT/bin/python3" <<'EOF'
#!/bin/bash
if [[ "$1" == */run-command.py && "$2" == --timeout ]]; then
    echo "timeout --process-tree $3" >>"$CALL_LOG"
fi
exec "$REAL_PYTHON3" "$@"
EOF
chmod +x "$TEST_ROOT/bin/"*

fail() { echo "FAIL: $1" >&2; exit 1; }
run_probe() {
    PATH="$TEST_ROOT/bin:$PATH" AZURE_RESOURCE_GROUP="${PROBE_RG-rg}" \
        AZURE_LOCATION="${PROBE_LOCATION-westus3}" AZURE_SUBSCRIPTION_ID="${PROBE_SUBSCRIPTION-}" \
        RTC_POSTGRES_PROBE_WAIT_SECONDS="${PROBE_WAIT-0}" "$PROBE"
}
reset() {
    : >"$CALL_LOG"
    rm -f "$RTC_POSTGRES_PROBE_RESULT_FILE"
    rm -f "$SERVER_STATE" "$SERVER_STATE.attempted"
    printf '%s\n' "$@" >"$CREATE_RESULTS"
}
count() { grep -c "^az postgres flexible-server $1 " "$CALL_LOG" || true; }
expect_status() {
    local expected="$1"
    shift
    local status=0
    output=$("$@" 2>&1) || status=$?
    [[ "$status" == "$expected" ]] || fail "expected status $expected, got $status: $output"
}

reset ok
expect_status 0 run_probe
[[ "$(count create)" == 1 && "$(count delete)" == 1 && "$(count show)" == 3 ]] || fail "absence/create/ownership/delete/show sequence"
grep -qE -- '--name pgprobe-[0-9a-f]{32} ' "$CALL_LOG" || fail "128-bit random server name"
grep -qE -- '--tags rtc-probe-owner=[0-9a-f]{32} ' "$CALL_LOG" || fail "creation-time ownership tag"
for setting in '--sku-name Standard_B1ms' '--tier Burstable' '--location westus3' '--storage-size 32' \
    '--version 16' '--zonal-resiliency Disabled' '--geo-redundant-backup Disabled' \
    '--microsoft-entra-auth Enabled' '--password-auth Enabled' '--public-access None'; do
    grep -q -- "$setting" "$CALL_LOG" || fail "missing $setting"
done
! grep -qE -- '--no-wait|--subscription|require_secure_transport' "$CALL_LOG" || fail "unexpected probe flags"
password="$(grep -oE -- '--admin-password [^ ]+' "$CALL_LOG" | cut -d' ' -f2)"
! grep -qF "$password" <<<"$output" || fail "password leaked to output"
! grep -qF "$password" "$RTC_POSTGRES_PROBE_RESULT_FILE" || fail "password leaked to result"
jq -e '.outcome == "available" and .errorCode == "" and .cleanup == "confirmed"' \
    "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null || fail "success record"
reset ok
expect_status 0 env OLD_CLI=1 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
grep -q -- '--high-availability Disabled' "$CALL_LOG" || fail "old CLI HA option"
grep -q -- '--active-directory-auth Enabled' "$CALL_LOG" || fail "old CLI Entra option"
reset ok
expect_status 1 env RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=5 CLI_HELP_RESULT=124 \
    AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(count create)" == 0 ]] || fail "ordinary help failure must not create a server"
reset ok
expect_status 1 env RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=5 CLI_HELP_RESULT=137 \
    AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(count create)" == 0 ]] || fail "ordinary help failure must not create a server"
reset ok
expect_status 3 env RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=1 CLI_HELP_SLEEP=20 \
    AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(count create)" == 0 ]] || fail "create-budget help timeout must not create a server"
reset ok
expect_status 1 env CLI_HELP_RESULT=1 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(count create)" == 0 ]] || fail "help failure must not create a server"
reset ok
expect_status 1 env UNSUPPORTED_CLI=1 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(count create)" == 0 ]] || fail "unsupported CLI must not create a server"

reset ok
expect_status 0 env RTC_POSTGRES_TEST_SIZE=M AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
    PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
grep -q -- '--sku-name Standard_D2ds_v5 --storage-size' "$CALL_LOG" || fail "M SKU"
grep -q -- '--tier GeneralPurpose' "$CALL_LOG" || fail "M tier"

reset capacity busy ok
expect_status 0 run_probe
[[ "$(count create)" == 3 && "$(count delete)" == 3 && "$(count show)" == 9 ]] || fail "retry cleanup"
[[ "$(grep -oE -- '--name [^ ]+' "$CALL_LOG" | sort -u | wc -l)" -eq 3 ]] || fail "unique server names"
[[ "$(awk '/^az / && !/list-skus/ {print $4}' "$CALL_LOG" | paste -sd,)" == "show,create,show,delete,show,show,create,show,delete,show,show,create,show,delete,show" ]] ||
    fail "must confirm deletion before next allocation"

reset ok
MULTILINE_SHOW=1 expect_status 0 run_probe
[[ "$(count show)" == 3 && "$(count create)" == 1 && "$(count delete)" == 1 ]] ||
    fail "real CLI absence envelopes must pass before creation and after deletion"
reset multiline-capacity multiline-busy ok
MULTILINE_SHOW=1 expect_status 0 run_probe
[[ "$(count create)" == 3 && "$(count delete)" == 3 ]] ||
    fail "real CLI capacity envelopes must permit bounded fallback"
for result in multiline-mixed multiline-uncoded multiline-inconsistent multiline-contradictory multiline-details; do
    reset "$result" ok
    MULTILINE_SHOW=1 expect_status 1 run_probe
    [[ "$(count create)" == 1 ]] || fail "mixed CLI envelopes must stop allocation"
done
reset ok
MULTILINE_SHOW=1 MULTILINE_SHOW_MESSAGE='Authorization denied.' expect_status 1 run_probe
[[ "$(count create)" == 0 ]] || fail "contradictory absence message must block allocation"

reset ok
expect_status 1 env DELETE_MISSING=1 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
reset ok
expect_status 0 env AZURE_SUBSCRIPTION_ID=sub-123 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(grep -c -- '--subscription sub-123' "$CALL_LOG")" == 6 ]] || fail "subscription on all calls"

reset capacity capacity capacity
expect_status 2 run_probe
[[ "$(count create)" == 3 ]] || fail "standalone retry bound"
grep -q 'This is an Azure capacity limit, not a recipe failure' <<<"$output" || fail "capacity message"
reset json
expect_status 2 env RTC_POSTGRES_PROBE_ATTEMPTS=1 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"

for result in other misleading text quota policy mixed uncoded uncoded-json; do
    reset "$result" ok
    expect_status 1 run_probe
    [[ "$(count create)" == 1 && "$(count show)" == 3 ]] || fail "$result must stop after confirmed cleanup"
done
reset other
expect_status 1 run_probe
grep -q 'probe stage=create exit_status=1 error_codes=AuthorizationFailed' <<<"$output" ||
    fail "create failure must report its stage, status, and parsed code"
reset leak
expect_status 1 run_probe
password="$(grep -oE -- '--admin-password [^ ]+' "$CALL_LOG" | cut -d' ' -f2)"
! grep -qF "$password" <<<"$output" || fail "password leaked from Azure error"
reset ok
expect_status 1 env SHOW_ERROR=AuthorizationFailed AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
    PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
grep -q 'cleanup stage=show exit_status=1 error_codes=AuthorizationFailed .*outcome_before_cleanup=available error_code_before_cleanup=none' \
    <<<"$output" || fail "show cleanup failure diagnostics"

reset ok
expect_status 1 env OWNERSHIP=foreign AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
    PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
grep -q 'cleanup stage=show exit_status=0 error_codes=OwnershipUnconfirmed .*outcome_before_cleanup=available error_code_before_cleanup=none' \
    <<<"$output" || fail "ownership cleanup failure diagnostics"
[[ "$(count delete)" == 0 ]] || fail "unverified ownership must not delete"

reset ok
expect_status 1 env RTC_POSTGRES_PROBE_CLEANUP_DEADLINE_EPOCH=1 AZURE_RESOURCE_GROUP=rg \
    AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
grep -q 'cleanup stage=deadline exit_status=124 error_codes=none .*outcome_before_cleanup=available error_code_before_cleanup=none' \
    <<<"$output" || fail "deadline cleanup failure diagnostics"
[[ "$(count delete)" == 0 ]] || fail "expired cleanup deadline must not delete"

reset ok
expect_status 1 env DELETE_FAILS=1 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
    PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
grep -q 'cleanup stage=delete exit_status=1 error_codes=Conflict .*outcome_before_cleanup=available error_code_before_cleanup=none' \
    <<<"$output" || fail "delete cleanup failure diagnostics"

reset ok
expect_status 1 env SERVER_REMAINS=1 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
    PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
grep -q 'cleanup stage=confirm exit_status=0 error_codes=none .*outcome_before_cleanup=available error_code_before_cleanup=none' \
    <<<"$output" || fail "confirmation cleanup failure diagnostics"

reset capacity
expect_status 1 env RTC_POSTGRES_PROBE_ATTEMPTS=1 DELETE_FAILS=1 AZURE_RESOURCE_GROUP=rg \
    AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
grep -q 'probe stage=create exit_status=1 error_codes=SkuNotAvailable' <<<"$output" ||
    fail "first create error must be retained"
grep -q 'cleanup stage=delete exit_status=1 error_codes=Conflict first_error_stage=create first_error_status=1 first_error_code=SkuNotAvailable outcome_before_cleanup=capacity_exhausted error_code_before_cleanup=SkuNotAvailable' \
    <<<"$output" || fail "cleanup failure must preserve the initial create error"
jq -e '.errorCode == "CleanupFailed" and .cleanup == "failed"' \
    "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null || fail "cleanup result"

reset timeout
expect_status 1 env DELETE_FAILS=1 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
    PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
grep -q 'cleanup stage=delete exit_status=1 error_codes=Conflict first_error_stage=create first_error_status=124 first_error_code=none outcome_before_cleanup=timeout error_code_before_cleanup=CreateTimeout' \
    <<<"$output" || fail "cleanup failure must preserve the initial create timeout"

reset timeout
expect_status 3 run_probe
[[ "$(count delete)" == 1 && "$(count show)" == 3 ]] || fail "timeout cleanup"
jq -e '.outcome == "timeout" and .errorCode == "CreateTimeout" and .cleanup == "uncertain"' \
    "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null || fail "timeout result"
grep -qE '^timeout --process-tree (89[0-9]|900)$' "$CALL_LOG" || fail "bounded create"
reset slow
expect_status 3 env RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=2 AZURE_RESOURCE_GROUP=rg \
    AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(count delete)" == 1 && "$(count show)" == 3 ]] || fail "real timeout must confirm cleanup"
grep -qE '^timeout --process-tree [12]$' "$CALL_LOG" || fail "configured create timeout"
reset capacity ok
expect_status 1 env RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS=1 DELETE_SLEEP=20 AZURE_RESOURCE_GROUP=rg \
    AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(count create)" == 1 ]] || fail "delete timeout must prevent another create"
jq -e '.errorCode == "CleanupFailed"' "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null || fail "delete timeout result"
for status in 124 137; do
    reset capacity ok
    expect_status 1 env INTERRUPTED_DELETE_STATUS="$status" DELETE_REMOVES_BEFORE_STATUS=1 \
        RTC_POSTGRES_PROBE_ATTEMPTS=2 RTC_POSTGRES_PROBE_WAIT_SECONDS=0 \
        AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
    [[ "$(count create)" == 1 && "$(count delete)" == 1 && ! -f "$SERVER_STATE" ]] ||
        fail "timed-out delete must prevent another allocation even after removing the server"
    jq -e '.outcome == "probe_error" and .errorCode == "CleanupFailed" and .cleanup == "failed"' \
        "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null || fail "timed-out deletion must not confirm cleanup"
done

for setting in EXISTING_SERVER=1 PRECHECK_ERROR=AuthorizationFailed; do
    reset ok
    expect_status 1 env "$setting" AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
        PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
    [[ "$(count create)" == 0 && "$(count delete)" == 0 && "$(count show)" == 1 ]] ||
        fail "existing or uncertain server must not be created or deleted"
done
reset ok
expect_status 1 env PRECHECK_ERROR=AuthorizationFailed AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
    PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
grep -q 'probe stage=pre-create read exit_status=1 error_codes=AuthorizationFailed' <<<"$output" ||
    fail "pre-create read failure must report its stage, status, and parsed code"
reset ok
expect_status 1 env PRECHECK_ERROR=LocationIsOfferRestricted AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
    PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
grep -q 'probe stage=pre-create read exit_status=1 error_codes=LocationIsOfferRestricted' <<<"$output" ||
    fail "safe provider identifiers must be preserved"
jq -e '.diagnostic.errorCode == "LocationIsOfferRestricted"' \
    "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null ||
    fail "safe provider identifier must remain in the probe result"
reset ok
expect_status 3 env PRECHECK_SLEEP=20 RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=1 \
    AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(count create)" == 0 && "$(count delete)" == 0 ]] || fail "absence timeout must stop allocation"
reset exists ok
expect_status 1 run_probe
[[ "$(count create)" == 1 && "$(count delete)" == 0 ]] ||
    fail "a create-name race must not delete the other owner's server or allocate again"

for result in ok capacity other timeout slow; do
    for setting in OWNERSHIP=foreign OWNERSHIP=missing OWNERSHIP=malformed \
        OWNERSHIP_ERROR=AuthorizationFailed OWNERSHIP_SLEEP=20; do
        reset "$result" ok
        create_limit=10
        [[ "$result" != slow ]] || create_limit=3
        expect_status 1 env "$setting" RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS="$create_limit" \
            RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS=1 AZURE_RESOURCE_GROUP=rg \
            AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
        [[ "$(count create)" == 1 && "$(count delete)" == 0 ]] ||
            fail "$result with $setting must not delete or allocate again"
        jq -e '.errorCode == "CleanupFailed"' "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null ||
            fail "ownership uncertainty must report cleanup failure"
    done
done
for result in other timeout; do
    reset "$result" ok
    expected=1
    [[ "$result" != timeout ]] || expected=3
    expect_status "$expected" env CREATE_ABSENT=1 AZURE_RESOURCE_GROUP=rg \
        AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
    [[ "$(count create)" == 1 && "$(count delete)" == 0 ]] ||
        fail "$result without a server must confirm absence without deletion"
    if [[ "$result" == timeout ]]; then
        server="$(grep '^az postgres flexible-server create ' "$CALL_LOG" | grep -oE -- '--name [^ ]+' | cut -d' ' -f2)"
        owner="${server#pgprobe-}"
        grep -Fq "probe server '$server' in resource group 'rg'" <<<"$output" ||
            fail "timeout must report the exact target for later inspection"
        grep -Fq "rtc-probe-owner=$owner" <<<"$output" || fail "timeout must report the expected ownership tag"
        grep -Fq 'does not rule out later creation' <<<"$output" ||
            fail "timeout must not claim immediate absence prevents later creation"
        jq -e '.outcome == "timeout" and .errorCode == "CreateTimeout" and .cleanup == "uncertain"' \
            "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null || fail "absent timeout result"
    fi
done
for interruption_attempt in {1..10}; do
    startup_delay=0
    [[ "$interruption_attempt" != 10 ]] || startup_delay=6
    signal_name=TERM
    ((interruption_attempt % 2 == 0)) && signal_name=INT
    reset slow ok
    ready_file="$TEST_ROOT/create-ready"
    rm -f -- "$ready_file"
    # Signal only after create starts; fixed sleeps can interrupt setup on busy runners.
    expect_status 1 env CREATE_ABSENT=1 CLI_HELP_SLEEP="$startup_delay" \
        RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=30 RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS=10 \
        AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 CREATE_READY_FILE="$ready_file" \
        PATH="$TEST_ROOT/bin:$PATH" "$REAL_PYTHON3" - "$PROBE" "$ready_file" "$signal_name" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

process = subprocess.Popen([sys.argv[1]], start_new_session=True)
try:
    deadline = time.monotonic() + 20
    ready_file = Path(sys.argv[2])
    while not ready_file.exists() or not ready_file.read_text().strip():
        if process.poll() is not None:
            raise RuntimeError(f"probe exited before create readiness: {process.returncode}")
        if time.monotonic() >= deadline:
            raise TimeoutError("probe did not reach create readiness")
        time.sleep(0.01)
    process.send_signal(getattr(signal, f"SIG{sys.argv[3]}"))
    status = process.wait(timeout=20)
    state_file = Path(f"/proc/{int(ready_file.read_text())}/stat")
    try:
        state = state_file.read_text().split(") ", 1)[1][0]
    except FileNotFoundError:
        pass
    else:
        assert state == "Z", "create process still running"
finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
sys.exit(status)
PY
    [[ "$(count create)" == 1 && "$(count delete)" == 0 && "$(count show)" == 2 ]] ||
        fail "interrupted create must check ownership without deletion or another allocation"
    server="$(grep '^az postgres flexible-server create ' "$CALL_LOG" | grep -oE -- '--name [^ ]+' | cut -d' ' -f2)"
    grep -Fq "probe server '$server' in resource group 'rg'" <<<"$output" ||
        fail "interrupted create must report the exact recovery target"
    grep -Fq "rtc-probe-owner=${server#pgprobe-}" <<<"$output" ||
        fail "interrupted create must report its expected ownership tag"
    grep -Fq 'does not rule out later creation' <<<"$output" ||
        fail "interrupted create must warn about late creation"
    jq -e '.outcome == "probe_error" and .errorCode == "CreateInterrupted" and .cleanup == "uncertain"' \
        "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null ||
        fail "interrupted create result: $(cat "$RTC_POSTGRES_PROBE_RESULT_FILE"); output: $output"
    grep -Fq 'Recovery target:' <<<"$output" || fail "recovery target must be logged before create"
done
for interrupted_status in 130 143; do
    for call in CLI_HELP_RESULT CATALOG_INTERRUPTED_STATUS; do
        reset ok
        expect_status 1 env "$call=$interrupted_status" AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
            PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
        [[ "$(count create)" == 0 ]] || fail "interrupted discovery must block allocation"
    done
    for stage in pre ownership deleted; do
        reset capacity ok
        expect_status 1 env INTERRUPTED_SHOW_STAGE="$stage" INTERRUPTED_STATUS="$interrupted_status" \
            AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
        if [[ "$stage" == pre ]]; then
            [[ "$(count create)" == 0 ]] || fail "interrupted absence check must block creation"
            jq -e '.cleanup == "not_required"' "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null ||
                fail "no allocation must report no cleanup required"
        else
            [[ "$(count create)" == 1 ]] || fail "interrupted cleanup must block another allocation"
            jq -e '.outcome == "probe_error" and .errorCode == "CleanupFailed"' \
                "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null ||
                fail "interrupted cleanup must not confirm absence"
        fi
    done
    reset capacity ok
    expect_status 1 env INTERRUPTED_DELETE_STATUS="$interrupted_status" \
        AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
    [[ "$(count create)" == 1 ]] || fail "interrupted deletion must block another allocation"
done
for result in interrupted-int interrupted-term interrupted-capacity-int interrupted-capacity-term; do
    for absent in 0 1; do
        reset "$result" ok
        create_absent=()
        [[ "$absent" == 0 ]] || create_absent=(CREATE_ABSENT=1)
        expect_status 1 env "${create_absent[@]}" AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
            PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
        [[ "$(count create)" == 1 ]] || fail "interrupted child must block another allocation"
        [[ "$absent" == 1 || "$(count delete)" == 1 ]] ||
            fail "interrupted child must still clean up its owned partial server"
        jq -e '.outcome == "probe_error" and .errorCode == "CreateInterrupted" and .cleanup == "uncertain"' \
            "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null ||
            fail "interrupted child result: $(cat "$RTC_POSTGRES_PROBE_RESULT_FILE"); output: $output"
        grep -Fq 'does not rule out later creation' <<<"$output" ||
            fail "interrupted child must warn about late creation"
    done
done
for format in plain json envelope; do
    for stage in pre ownership deleted; do
        reset ok ok
        expect_status 1 env MIXED_SHOW_STAGE="$stage" MIXED_FORMAT="$format" \
            AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
        if [[ "$stage" == pre ]]; then
            [[ "$(count create)" == 0 && "$(count delete)" == 0 ]] ||
                fail "mixed absence errors must not authorize allocation or deletion"
            jq -e '.errorCode == "ServerAbsenceUnknown"' "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null ||
                fail "mixed pre-create read must report unknown absence"
        else
            [[ "$(count create)" == 1 ]] || fail "mixed cleanup errors must stop allocation"
            [[ "$stage" != ownership || "$(count delete)" == 0 ]] ||
                fail "mixed ownership read must not authorize deletion"
            jq -e '.errorCode == "CleanupFailed"' "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null ||
                fail "mixed cleanup errors must not report confirmed cleanup"
        fi
    done
done
reset ok
expect_status 0 env CATALOG_SLEEP=1 PRECHECK_SLEEP=1 OWNERSHIP_SLEEP=1 \
    RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=10 RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS=10 \
    AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
awk '
    /^timeout / { limit = $3 }
    /^az postgres flexible-server create / { if (limit <= 0 || limit >= 10) exit 1; create++ }
    /^az postgres flexible-server delete / { if (limit <= 0 || limit >= 10) exit 1; deletes++ }
    END { if (create != 1 || deletes != 1) exit 1 }
' "$CALL_LOG" || fail "absence and ownership reads must reduce the create and cleanup budgets"

for field in Version Tier Sku Storage; do
    case "$field" in
        Version) catalog="$(jq '.[0].supportedServerVersions[0].name = "15"' <<<"$CATALOG_JSON")" ;;
        Tier) catalog="$(jq '.[0].supportedServerEditions[0].name = "Other"' <<<"$CATALOG_JSON")" ;;
        Sku) catalog="$(jq '.[0].supportedServerEditions[0].supportedServerSkus = []' <<<"$CATALOG_JSON")" ;;
        Storage) catalog="$(jq '.[0].supportedServerEditions[0].supportedStorageEditions[0].supportedStorageMb[0].storageSizeMb = 65536' <<<"$CATALOG_JSON")" ;;
    esac
    reset ok
    expect_status 4 env CATALOG_JSON="$catalog" AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
        PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
    [[ "$(count create)" == 0 ]] || fail "unsupported $field must not allocate"
    jq -e --arg code "Unsupported$field" \
        '.outcome == "unsupported" and .errorCode == $code and .cleanup == "not_required"' \
        "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null || fail "unsupported $field result"
done
for catalog in 'not json' '[{}]' \
    '[{"status":123,"supportedServerVersions":[],"supportedServerEditions":[]}]' \
    '[{"status":"Unknown","supportedServerVersions":[],"supportedServerEditions":[]}]'; do
    reset ok
    expect_status 1 env CATALOG_JSON="$catalog" AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
        PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
    [[ "$(count create)" == 0 ]] || fail "malformed catalog must not allocate"
    jq -e '.outcome == "probe_error"' "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null ||
        fail "malformed catalog result"
done
for catalog in '[]' \
    '[{"reason":"Subscription restriction","supportedServerVersions":[],"supportedServerEditions":[]}]' \
    '[{"supportedServerVersions":[],"supportedServerEditions":[]}]'; do
    reset ok
    expect_status 5 env CATALOG_JSON="$catalog" AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
        PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
    [[ "$(count create)" == 0 ]] || fail "restricted catalog must not allocate"
    jq -e '.outcome == "restricted" and .errorCode == "RegionRestricted" and
        .cleanup == "not_required"' "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null ||
        fail "restricted catalog result"
done
reset ok
expect_status 5 env CATALOG_JSON="$(jq '.[0].supportedFeatures[0].status = "Enabled"' <<<"$CATALOG_JSON")" \
    AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(count create)" == 0 ]] || fail "OfferRestricted must stop allocation"
jq -e '.outcome == "restricted" and .errorCode == "RegionRestricted" and
    .cleanup == "not_required"' \
    "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null || fail "explicit catalog restriction result"
reset ok
expect_status 1 env CATALOG_FAIL=1 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
    PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(count create)" == 0 ]] || fail "catalog provider failure must not allocate"
reset ok
expect_status 3 env CATALOG_SLEEP=20 RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=1 \
    AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(count create)" == 0 ]] || fail "catalog timeout must not allocate"

# Renew on every real wrapper call, including help with discarded stderr.
mv "$TEST_ROOT/bin/az" "$TEST_ROOT/bin/provider-az"
cp "$REPO_ROOT/.github/scripts/azure-cli-with-refresh.sh" "$TEST_ROOT/bin/az"
cat >"$TEST_ROOT/bin/curl" <<'EOF'
#!/bin/bash
echo '{"value":"test-probe-assertion"}'
EOF
cat >"$TEST_ROOT/bin/date" <<'EOF'
#!/bin/bash
now=1000000
[[ ! -f "$LOGIN_CLOCK" ]] || read -r now <"$LOGIN_CLOCK"
echo $((now + 240)) >"$LOGIN_CLOCK"
echo "$now"
EOF
chmod +x "$TEST_ROOT/bin/"*
export RTC_AZURE_CLI="$TEST_ROOT/bin/provider-az" RTC_AZURE_LOGIN_STAMP="$TEST_ROOT/login-stamp"
export LOGIN_CLOCK="$TEST_ROOT/login-clock"
export AZURE_CLIENT_ID=client AZURE_TENANT_ID=tenant
export ACTIONS_ID_TOKEN_REQUEST_URL=https://example.invalid/token ACTIONS_ID_TOKEN_REQUEST_TOKEN=fake-request
for result in ok capacity mixed; do
    reset "$result"
    expected=0
    [[ "$result" != capacity ]] || expected=2
    [[ "$result" != mixed ]] || expected=1
    expect_status "$expected" env RTC_POSTGRES_PROBE_ATTEMPTS=1 \
        AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 AZURE_SUBSCRIPTION_ID=subscription \
        PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
    [[ "$(count create)" == 1 && "$(count delete)" == 1 ]] || fail "renewal must not prevent owned cleanup"
    [[ "$(grep -c '^::add-mask::test-probe-assertion$' <<<"$output")" == 7 ]] ||
        fail "every renewal must deliver its mask outside captured help and provider diagnostics"
    ! grep -Fq test-probe-assertion "$RTC_POSTGRES_PROBE_RESULT_FILE" "$CALL_LOG" ||
        fail "renewal token must not enter artifacts or call logs"
    ! grep -v '^::add-mask::test-probe-assertion$' <<<"$output" | grep -Fq test-probe-assertion ||
        fail "renewal token must appear only in mask commands"
    jq -e '.cleanup == "confirmed"' "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null ||
        fail "renewal must not change cleanup evidence"
    if [[ "$result" == mixed ]]; then
        jq -e '.outcome == "probe_error" and (.errorCode | contains("AuthorizationFailed"))' \
            "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null || fail "renewal must not hide mixed provider errors"
    fi
done
mv "$TEST_ROOT/bin/provider-az" "$TEST_ROOT/bin/az"
rm -f -- "$TEST_ROOT/bin/date"

python3 - "$REPO_ROOT/.github/scripts/run-command.py" <<'PY'
import signal
from pathlib import Path
import subprocess
import sys
import time

def assert_stopped(pids):
    for pid in pids.split():
        state_file = Path(f"/proc/{int(pid)}/stat")
        for _ in range(50):
            try:
                state = state_file.read_text().split(") ", 1)[1].split()[0]
            except FileNotFoundError:
                break
            if state == "Z":
                break
            time.sleep(0.01)
        else:
            raise AssertionError(f"descendant {pid} is still running")

for command in (
    'sleep 6 & child=$!; echo "$$ $child"; wait; echo false',
    'trap "" TERM; sleep 6 & child=$!; echo "$$ $child"; wait; echo false',
    'sleep 6 & echo "$!"; exit 0',
):
    started = time.monotonic()
    result = subprocess.run(
        [sys.executable, sys.argv[1], "--timeout", "1", "--", "bash", "-c", command],
        capture_output=True, text=True, timeout=3,
    )
    assert result.returncode in (0, 124), result
    assert time.monotonic() - started < 3 and "false" not in result.stdout, result
    assert_stopped(result.stdout.strip())

process = subprocess.Popen(
    [sys.executable, sys.argv[1], "--timeout", "20", "--", "bash", "-c",
     'trap "" TERM; sleep 6 & child=$!; echo "$$ $child"; wait; echo false'],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
)
pids = process.stdout.readline().strip()
process.send_signal(signal.SIGTERM)
output, errors = process.communicate(timeout=3)
assert process.returncode == 143 and "false" not in output, (output, errors)
assert_stopped(pids)
PY

for setting in RTC_POSTGRES_TEST_SIZE=L RTC_POSTGRES_TEST_SIZE=bad RTC_POSTGRES_TEST_SIZE= \
    RTC_POSTGRES_PROBE_ATTEMPTS=0 RTC_POSTGRES_PROBE_ATTEMPTS=4 RTC_POSTGRES_PROBE_ATTEMPTS=99999999999999999 \
    RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=0 RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=901 \
    RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS=-1 RTC_POSTGRES_PROBE_WAIT_SECONDS=601 \
    RTC_POSTGRES_PROBE_CLEANUP_DEADLINE_EPOCH=bad; do
    reset ok
    expect_status 1 env "$setting" AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
    [[ ! -s "$CALL_LOG" ]] || fail "invalid input must not call Azure: $setting"
done
reset ok
expect_status 1 env AZURE_RESOURCE_GROUP= AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ ! -s "$CALL_LOG" ]] || fail "missing group must not call Azure"
echo "PostgreSQL capacity probe tests passed"
