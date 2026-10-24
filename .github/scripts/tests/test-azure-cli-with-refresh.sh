#!/bin/bash
# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-azure-auth-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/runner"
export CALL_LOG="$TEST_ROOT/calls"
export PATH="$TEST_ROOT/bin:$PATH"
export AZURE_CLIENT_ID=client AZURE_TENANT_ID=tenant AZURE_SUBSCRIPTION_ID=subscription
export ACTIONS_ID_TOKEN_REQUEST_URL='https://example.invalid/token?api-version=2'
export ACTIONS_ID_TOKEN_REQUEST_TOKEN=test-request-token
export NOW=10000
export RUNNER_TEMP="$TEST_ROOT/runner" GITHUB_ENV="$TEST_ROOT/env" GITHUB_PATH="$TEST_ROOT/path"
cat >"$TEST_ROOT/bin/az" <<'EOF'
#!/bin/bash
echo "$1 ${2:-}" >>"$CALL_LOG"
case "$1 ${2:-}" in
    login\ *)
        [[ "$*" == *'--federated-token test-assertion'* ]] || exit 99
        exit "${LOGIN_STATUS:-0}" ;;
    "account set") exit "${ACCOUNT_STATUS:-0}" ;;
    *) printf '%s\n' '{"value":"command-result"}'; exit "${COMMAND_STATUS:-0}" ;;
esac
EOF
cat >"$TEST_ROOT/bin/curl" <<'EOF'
#!/bin/bash
echo curl >>"$CALL_LOG"
[[ "$*" == *'audience=api%3A%2F%2FAzureADTokenExchange'* ]] || exit 99
[[ "$*" == *'Authorization: bearer test-request-token'* ]] || exit 99
printf '%s\n' "${TOKEN_RESPONSE:-{\"value\":\"test-assertion\"}}"
exit "${CURL_STATUS:-0}"
EOF
cat >"$TEST_ROOT/bin/date" <<'EOF'
#!/bin/bash
echo "$NOW"
EOF
chmod +x "$TEST_ROOT/bin/"*

fail() { echo "FAIL: $1" >&2; exit 1; }
script="$REPO_ROOT/.github/scripts/azure-cli-with-refresh.sh"
bash "$script" --install
export RTC_AZURE_CLI="$TEST_ROOT/bin/az"
export RTC_AZURE_LOGIN_STAMP="$RUNNER_TEMP/rtc-azure-cli/login-stamp"
wrapper="$RUNNER_TEMP/rtc-azure-cli/az"
grep -Fxq "RTC_AZURE_CLI=$RTC_AZURE_CLI" "$GITHUB_ENV" || fail "must preserve real CLI path"
grep -Fxq "$RUNNER_TEMP/rtc-azure-cli" "$GITHUB_PATH" || fail "must install on later steps' PATH"

run_cli() { "$wrapper" lock list --output json >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"; }
run_cli || fail "first command must succeed"
[[ "$(cat "$TEST_ROOT/out")" == '{"value":"command-result"}' ]] || fail "stdout must remain valid CLI JSON"
[[ "$(cat "$RTC_AZURE_LOGIN_STAMP")" == 10000 ]] || fail "successful login must record renewal time"
[[ "$(grep -c '^login ' "$CALL_LOG")" == 1 ]] || fail "first command must log in"
grep -q '^::add-mask::test-assertion$' "$TEST_ROOT/err" || fail "assertion must be masked"

NOW=10239 run_cli || fail "cached login must work"
[[ "$(grep -c '^login ' "$CALL_LOG")" == 1 ]] || fail "valid login must be reused"
NOW=10240 run_cli || fail "old login must renew"
[[ "$(grep -c '^login ' "$CALL_LOG")" == 2 ]] || fail "must renew before assertion expires"
NOW=9000 run_cli || fail "clock rollback must renew"
[[ "$(cat "$RTC_AZURE_LOGIN_STAMP")" == 9000 ]] || fail "clock rollback must not retain a future stamp"
NOW=14000 run_cli || fail "a command after an hour must get a fresh login"
[[ "$(cat "$RTC_AZURE_LOGIN_STAMP")" == 14000 ]] || fail "hour-long test run must not reuse its first assertion"

for failure in CURL_STATUS LOGIN_STATUS ACCOUNT_STATUS; do
    echo 1 >"$RTC_AZURE_LOGIN_STAMP"
    : >"$CALL_LOG"
    if (export "$failure=1"; run_cli); then fail "$failure must fail closed"; fi
    [[ "$(cat "$RTC_AZURE_LOGIN_STAMP")" == 1 ]] || fail "$failure must not mark renewal successful"
    if grep -q '^lock ' "$CALL_LOG"; then fail "$failure must not execute the requested command"; fi
done
for response in '{}' '{"value":""}' '{"value":1}' 'invalid-json'; do
    : >"$CALL_LOG"
    if TOKEN_RESPONSE="$response" run_cli; then fail "invalid OIDC response must fail"; fi
    if grep -q '^login ' "$CALL_LOG"; then fail "invalid OIDC response must not reach login"; fi
done
for stamp in '' 'not-a-timestamp'; do
    printf '%s\n' "$stamp" >"$RTC_AZURE_LOGIN_STAMP"
    : >"$CALL_LOG"
    if run_cli; then fail "invalid login timestamp must fail explicitly"; fi
    grep -q 'Error:.*Azure login timestamp' "$TEST_ROOT/err" || fail "timestamp error must be explicit"
    if grep -q '^lock ' "$CALL_LOG"; then fail "invalid timestamp must not execute command"; fi
done

# Parallel callers must exchange only one assertion and keep separate output.
echo 1 >"$RTC_AZURE_LOGIN_STAMP"
: >"$CALL_LOG"
"$wrapper" lock list >"$TEST_ROOT/parallel-1" 2>"$TEST_ROOT/parallel-1.err" &
first=$!
"$wrapper" lock list >"$TEST_ROOT/parallel-2" 2>"$TEST_ROOT/parallel-2.err" &
second=$!
wait "$first" || fail "first parallel command failed"
wait "$second" || fail "second parallel command failed"
[[ "$(grep -c '^login ' "$CALL_LOG")" == 1 ]] || fail "parallel callers must share one renewal"
[[ "$(grep -c '^lock ' "$CALL_LOG")" == 2 ]] || fail "both commands must execute"

status=0
COMMAND_STATUS=7 run_cli || status=$?
[[ "$status" == 7 ]] || fail "must preserve requested command's exit code"
echo 1 >"$RTC_AZURE_LOGIN_STAMP"
: >"$CALL_LOG"
AZURE_CLIENT_ID="" ACTIONS_ID_TOKEN_REQUEST_TOKEN="" "$wrapper" logout >"$TEST_ROOT/out"
AZURE_CLIENT_ID="" ACTIONS_ID_TOKEN_REQUEST_TOKEN="" "$wrapper" account clear >"$TEST_ROOT/out"
if grep -q '^login ' "$CALL_LOG"; then fail "post-job logout must not renew"; fi
echo "Azure CLI renewal tests passed"
