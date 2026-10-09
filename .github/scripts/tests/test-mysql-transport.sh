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
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-mysql-transport-tests-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

cat >"$TEST_ROOT/mysql" <<'EOF'
#!/bin/sh
test "$MYSQL_PWD" = 'fixture-password' || exit 1
test "$*" = '--host=db --port=3306 --user=radadmin --database=appdb --connect-timeout=5 --batch --skip-column-names --execute=SELECT @@GLOBAL.require_secure_transport' || exit 1
test "${QUERY_FAIL:-0}" = 0 || exit 1
printf '%s\n' "$SERVER_SETTING"
EOF
chmod +x "$TEST_ROOT/mysql"
export PATH="$TEST_ROOT:$PATH"
export MYSQL_PASSWORD=fixture-password MYSQL_HOST=db MYSQL_PORT=3306 MYSQL_USER=radadmin MYSQL_DB=appdb

probe="$REPO_ROOT/Data/mySqlDatabases/test/verify-transport.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

MYSQL_TLS=required SERVER_SETTING=1 sh "$probe" || fail "required must accept an enabled server setting"
MYSQL_TLS=optional SERVER_SETTING=0 sh "$probe" || fail "optional must accept a disabled server setting"
if MYSQL_TLS=required SERVER_SETTING=0 sh "$probe" 2>/dev/null; then
    fail "required must reject a disabled server setting"
fi
if MYSQL_TLS=optional SERVER_SETTING=1 sh "$probe" 2>/dev/null; then
    fail "optional must reject an enabled server setting"
fi
for setting in '' NULL garbage; do
    if MYSQL_TLS=required SERVER_SETTING="$setting" sh "$probe" 2>/dev/null; then
        fail "invalid query output must fail"
    fi
done
if MYSQL_TLS=required SERVER_SETTING=1 QUERY_FAIL=1 sh "$probe" 2>/dev/null; then
    fail "query failure must fail"
fi

template="$REPO_ROOT/Data/mySqlDatabases/test/app.bicep"
grep -Fq "verifyTransport ? loadTextContent('verify-transport.sh')" "$template" ||
    fail "the direct-module readiness probe must run the tested script"
grep -q '    tls: tls$' "$template" || fail "test policy must reach the database resource"
grep -A1 'MYSQL_TLS: {' "$template" | grep -q 'value: tls' ||
    fail "the client probe must use the same test policy"

echo "MySQL transport tests passed"
