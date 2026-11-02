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

# Track ownership separately from the create result, including partial creates.
cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
set -euo pipefail
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
    delete)
        [[ -z "${DELETE_SLEEP:-}" ]] || sleep "$DELETE_SLEEP"
        if [[ -n "${DELETE_FAILS:-}" ]]; then echo '(Conflict) delete rejected' >&2; exit 1; fi
        if [[ -n "${DELETE_MISSING:-}" ]]; then echo '(ResourceNotFound) absent' >&2; exit 1; fi
        [[ -n "${SERVER_REMAINS:-}" ]] || rm -f "$SERVER_STATE"
        exit 0 ;;
    show)
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
        echo "(${SHOW_ERROR:-ResourceNotFound}) absent" >&2
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
    json) echo '{"error":{"code":"SkuNotAvailable","message":"Unavailable"}}' >&2 ;;
    mixed) printf '%s\n' '(SkuNotAvailable) Unavailable.' '(AuthorizationFailed) Denied.' >&2 ;;
    misleading) echo '(AuthorizationFailed) Cannot check SkuNotAvailable.' >&2 ;;
    text) echo 'CLI failed while reading SkuNotAvailable text.' >&2 ;;
    quota) echo '(QuotaExceeded) Quota exceeded.' >&2 ;;
    policy) echo '(RequestDisallowedByPolicy) Policy denied.' >&2 ;;
    leak) echo "(AuthorizationFailed) Request arguments: $*" >&2 ;;
    timeout) exit 124 ;;
    slow) sleep 20; exit 0 ;;
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
jq -e '.outcome == "available" and .errorCode == ""' "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null || fail "success record"
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
[[ "$(awk '/^az / {print $4}' "$CALL_LOG" | paste -sd,)" == "show,create,show,delete,show,show,create,show,delete,show,show,create,show,delete,show" ]] ||
    fail "must confirm deletion before next allocation"

reset ok
expect_status 1 env DELETE_MISSING=1 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
reset ok
expect_status 0 env AZURE_SUBSCRIPTION_ID=sub-123 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(grep -c -- '--subscription sub-123' "$CALL_LOG")" == 5 ]] || fail "subscription on all calls"

reset capacity capacity capacity
expect_status 2 run_probe
[[ "$(count create)" == 3 ]] || fail "standalone retry bound"
grep -q 'This is an Azure capacity limit, not a recipe failure' <<<"$output" || fail "capacity message"
reset json
expect_status 2 env RTC_POSTGRES_PROBE_ATTEMPTS=1 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"

for result in other misleading text quota policy mixed; do
    reset "$result" ok
    expect_status 1 run_probe
    [[ "$(count create)" == 1 && "$(count show)" == 3 ]] || fail "$result must stop after confirmed cleanup"
done
reset leak
expect_status 1 run_probe
password="$(grep -oE -- '--admin-password [^ ]+' "$CALL_LOG" | cut -d' ' -f2)"
! grep -qF "$password" <<<"$output" || fail "password leaked from Azure error"
for result in ok capacity timeout; do
    reset "$result"
    expect_status 1 env DELETE_FAILS=1 AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
    [[ "$(count create)" == 1 ]] || fail "cleanup failure must stop"
    jq -e '.errorCode == "CleanupFailed"' "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null || fail "cleanup result"
done
for setting in SERVER_REMAINS=1 SHOW_ERROR=AuthorizationFailed; do
    reset ok
    expect_status 1 env "$setting" AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
done
reset timeout
expect_status 3 run_probe
[[ "$(count delete)" == 1 && "$(count show)" == 3 ]] || fail "timeout cleanup"
jq -e '.outcome == "timeout" and .errorCode == "CreateTimeout"' "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null || fail "timeout result"
grep -qE '^timeout --signal=KILL (89[0-9]|900)$' "$CALL_LOG" || fail "bounded create"
reset slow
expect_status 3 env RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=2 AZURE_RESOURCE_GROUP=rg \
    AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(count delete)" == 1 && "$(count show)" == 3 ]] || fail "real timeout must confirm cleanup"
grep -qE '^timeout --signal=KILL [12]$' "$CALL_LOG" || fail "configured create timeout"
reset capacity ok
expect_status 1 env RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS=1 DELETE_SLEEP=20 AZURE_RESOURCE_GROUP=rg \
    AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ "$(count create)" == 1 ]] || fail "delete timeout must prevent another create"
jq -e '.errorCode == "CleanupFailed"' "$RTC_POSTGRES_PROBE_RESULT_FILE" >/dev/null || fail "delete timeout result"

for setting in EXISTING_SERVER=1 PRECHECK_ERROR=AuthorizationFailed; do
    reset ok
    expect_status 1 env "$setting" AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 \
        PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
    [[ "$(count create)" == 0 && "$(count delete)" == 0 && "$(count show)" == 1 ]] ||
        fail "existing or uncertain server must not be created or deleted"
done
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
done
reset ok
expect_status 0 env PRECHECK_SLEEP=1 OWNERSHIP_SLEEP=1 \
    RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=10 RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS=10 \
    AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
awk '
    /^timeout / { limit = $3 }
    /^az postgres flexible-server create / { if (limit <= 0 || limit >= 10) exit 1; create++ }
    /^az postgres flexible-server delete / { if (limit <= 0 || limit >= 10) exit 1; deletes++ }
    END { if (create != 1 || deletes != 1) exit 1 }
' "$CALL_LOG" || fail "absence and ownership reads must reduce the create and cleanup budgets"

for setting in RTC_POSTGRES_TEST_SIZE=L RTC_POSTGRES_TEST_SIZE=bad RTC_POSTGRES_TEST_SIZE= \
    RTC_POSTGRES_PROBE_ATTEMPTS=0 RTC_POSTGRES_PROBE_ATTEMPTS=4 RTC_POSTGRES_PROBE_ATTEMPTS=99999999999999999 \
    RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=0 RTC_POSTGRES_PROBE_CREATE_TIMEOUT_SECONDS=901 \
    RTC_POSTGRES_PROBE_DELETE_TIMEOUT_SECONDS=-1 RTC_POSTGRES_PROBE_WAIT_SECONDS=601; do
    reset ok
    expect_status 1 env "$setting" AZURE_RESOURCE_GROUP=rg AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
    [[ ! -s "$CALL_LOG" ]] || fail "invalid input must not call Azure: $setting"
done
reset ok
expect_status 1 env AZURE_RESOURCE_GROUP= AZURE_LOCATION=westus3 PATH="$TEST_ROOT/bin:$PATH" "$PROBE"
[[ ! -s "$CALL_LOG" ]] || fail "missing group must not call Azure"
echo "PostgreSQL capacity probe tests passed"
