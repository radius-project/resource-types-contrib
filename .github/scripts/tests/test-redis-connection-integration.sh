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
for dependency in docker openssl; do
    command -v "$dependency" >/dev/null || {
        echo "Error: Redis connection integration tests require $dependency." >&2
        exit 1
    }
done
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-redis-client-XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$TEST_ROOT/key.pem" -out "$TEST_ROOT/cert.pem" \
    -subj /CN=localhost -addext subjectAltName=DNS:localhost >"$TEST_ROOT/openssl.log" 2>&1 || {
        echo "Error: Could not create the local Redis test certificate." >&2
        exit 1
    }
cp "$REPO_ROOT/Data/redisCaches/test/verify-connection.sh" "$TEST_ROOT/probe.sh"

# No host ports or external network access; all credentials and certificates are fixtures.
docker run --rm -i --network none \
    --mount "type=bind,src=$TEST_ROOT,dst=/fixtures,readonly" \
    redis:7-alpine sh -s <<'SH'
set -eu
fail() { echo "FAIL: $1" >&2; exit 1; }
redis-server --port 0 --tls-port 10000 \
    --tls-cert-file /fixtures/cert.pem --tls-key-file /fixtures/key.pem \
    --tls-ca-cert-file /fixtures/cert.pem --tls-auth-clients no \
    --requirepass 'fixture+/key=' --daemonize yes
export SSL_CERT_FILE=/fixtures/cert.pem
export REDIS_PLATFORM=azure REDIS_HOST=localhost REDIS_PORT=10000
export REDIS_ACCESS_KEY='fixture+/key='
export REDIS_URL="rediss://:$REDIS_ACCESS_KEY@$REDIS_HOST:$REDIS_PORT"
export REDIS_CONNECTION_STRING="$REDIS_HOST:$REDIS_PORT,password=$REDIS_ACCESS_KEY,ssl=True,abortConnect=False"

ready=0
for attempt in 1 2 3 4 5; do
    if test "$(REDISCLI_AUTH="$REDIS_ACCESS_KEY" timeout 2 redis-cli --tls \
        -h "$REDIS_HOST" -p "$REDIS_PORT" PING 2>/dev/null)" = PONG; then
        ready=1
        break
    fi
    sleep 1
done
test "$ready" = 1 || fail "local TLS Redis did not start"
sh /fixtures/probe.sh || fail "real CLI must authenticate both Azure credential paths"

if REDIS_ACCESS_KEY=wrong REDIS_URL=rediss://:wrong@localhost:10000 \
    REDIS_CONNECTION_STRING=localhost:10000,password=wrong,ssl=True,abortConnect=False \
    sh /fixtures/probe.sh >/tmp/rejected 2>&1; then
    fail "a matching URL and connection string with the wrong key must fail"
fi
grep -q 'Redis connection check failed: access-key PING did not return PONG' /tmp/rejected ||
    fail "wrong credentials must fail at the authenticated PING"

redis-server --port 6379 --daemonize yes
REDIS_PLATFORM=kubernetes REDIS_URL=redis://localhost:6379 sh /fixtures/probe.sh ||
    fail "Kubernetes must still connect without credentials"
echo "Real Redis client connection tests passed"
SH
