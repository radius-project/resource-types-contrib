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
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-redis-connection-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

cat >"$TEST_ROOT/redis-cli" <<'EOF'
#!/bin/sh
case "$*" in
    '--no-auth-warning --tls -h cache.example -p 10000 PING')
        test "${REDISCLI_AUTH:-}" = 'fixture+/key=' || exit 1
        test "${FAIL_ACCESS_KEY:-0}" = 0 || exit 1
        ;;
    '--no-auth-warning -u rediss://:fixture+/key=@cache.example:10000 PING'|\
    '--no-auth-warning -u redis://cache.example:6379 PING')
        test "${FAIL_URL:-0}" = 0 || exit 1
        ;;
    *) exit 1 ;;
esac
printf '%s\n' "${PING_RESULT-PONG}"
EOF
chmod +x "$TEST_ROOT/redis-cli"
export PATH="$TEST_ROOT:$PATH"
export REDIS_PLATFORM=azure REDIS_HOST=cache.example REDIS_PORT=10000
export REDIS_ACCESS_KEY='fixture+/key='
export REDIS_URL="rediss://:$REDIS_ACCESS_KEY@$REDIS_HOST:$REDIS_PORT"
export REDIS_CONNECTION_STRING="$REDIS_HOST:$REDIS_PORT,password=$REDIS_ACCESS_KEY,ssl=True,abortConnect=False"
probe="$REPO_ROOT/Data/redisCaches/test/verify-connection.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

sh "$probe" || fail "Azure URL and separate access key must connect"
REDIS_PLATFORM=kubernetes REDIS_URL=redis://cache.example:6379 \
    REDIS_ACCESS_KEY='' REDIS_CONNECTION_STRING='' sh "$probe" ||
    fail "Kubernetes must connect without an access key or StackExchange string"

reject() {
    if env "$@" sh "$probe" >"$TEST_ROOT/output" 2>&1; then
        fail "invalid credentials or connection must fail: $*"
    fi
    grep -q 'Redis connection check failed:' "$TEST_ROOT/output" ||
        fail "failures must report a useful error"
    if grep -Fq "$REDIS_ACCESS_KEY" "$TEST_ROOT/output"; then
        fail "errors must not print credentials"
    fi
}

reject REDIS_ACCESS_KEY=
reject -u REDIS_ACCESS_KEY
reject REDIS_URL="$REDIS_CONNECTION_STRING"
reject REDIS_URL="redis://:$REDIS_ACCESS_KEY@$REDIS_HOST:$REDIS_PORT"
reject REDIS_URL="rediss://:wrong@$REDIS_HOST:$REDIS_PORT"
reject REDIS_CONNECTION_STRING=
reject -u REDIS_CONNECTION_STRING
reject REDIS_CONNECTION_STRING="$REDIS_URL"
reject FAIL_ACCESS_KEY=1
reject FAIL_URL=1
reject PING_RESULT='NOAUTH Authentication required.'
reject PING_RESULT=
reject REDIS_PLATFORM=unknown

for invalid_format in REDIS_URL=rediss://wrong REDIS_CONNECTION_STRING=wrong; do
    reject "$invalid_format"
    grep -Fq 'does not match the redis-enterprise:0.5.1 output contract; the AVM output format may have changed' \
        "$TEST_ROOT/output" || fail "format mismatches must identify the pinned AVM contract"
done

# shellcheck source=.github/scripts/lib-recipe-packs.sh
source "$REPO_ROOT/.github/scripts/lib-recipe-packs.sh"
entry="$(rtc_recipe_pack_entry_body \
    "$REPO_ROOT/recipe-packs/azure-aks/azure-aks.bicep" Radius.Data/redisCaches)"
for mapping in "accessKey: 'primaryAccessKey'" "url: 'primaryConnectionString'" \
    "connectionString: 'primaryStackExchangeRedisConnectionString'" \
    "accessKeysAuthentication: 'Enabled'" "clientProtocol: 'Encrypted'"; do
    grep -Fq "$mapping" <<<"$entry" || fail "Azure Redis mapping is missing: $mapping"
done
grep -Fq "loadTextContent('verify-connection.sh')" "$REPO_ROOT/Data/redisCaches/test/app.bicep" ||
    fail "the deployed test must run the checked connection probe"
if grep -Fq "\${" "$probe"; then
    fail "the embedded probe must not contain Terraform interpolation sequences"
fi

echo "Redis connection tests passed"
