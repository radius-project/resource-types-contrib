#!/bin/sh

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

set -eu

fail() {
    echo "Redis connection check failed: $1" >&2
    exit 1
}

case "$REDIS_PLATFORM" in
    azure)
        # Braced shell expansions are also parsed as Terraform interpolation.
        REDIS_ACCESS_KEY=$(printenv REDIS_ACCESS_KEY) || fail "access key is missing"
        test -n "$REDIS_ACCESS_KEY" || fail "access key is missing"
        REDIS_CONNECTION_STRING=$(printenv REDIS_CONNECTION_STRING) ||
            fail "StackExchange.Redis connection string is missing"
        test "$REDIS_URL" = "rediss://:$REDIS_ACCESS_KEY@$REDIS_HOST:$REDIS_PORT" ||
            fail "URL must contain the access key and use TLS"
        test "$REDIS_CONNECTION_STRING" = "$REDIS_HOST:$REDIS_PORT,password=$REDIS_ACCESS_KEY,ssl=True,abortConnect=False" ||
            fail "StackExchange.Redis connection string is invalid"
        pong=$(REDISCLI_AUTH="$REDIS_ACCESS_KEY" timeout 4 redis-cli --no-auth-warning \
            --tls -h "$REDIS_HOST" -p "$REDIS_PORT" PING 2>/dev/null) ||
            fail "access-key connection failed"
        test "$pong" = PONG || fail "access-key PING did not return PONG"
        ;;
    kubernetes)
        case "$REDIS_URL" in
            redis://*) ;;
            *) fail "Kubernetes URL must use redis://" ;;
        esac
        ;;
    *) fail "unknown platform" ;;
esac

pong=$(timeout 4 redis-cli --no-auth-warning -u "$REDIS_URL" PING 2>/dev/null) ||
    fail "URL connection failed"
test "$pong" = PONG || fail "URL PING did not return PONG"
