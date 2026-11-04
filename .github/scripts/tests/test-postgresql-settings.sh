#!/bin/bash
# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed
# under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
# CONDITIONS OF ANY KIND, either express or implied. See the License for the
# specific language governing permissions and limitations under the License.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-postgresql-settings-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat >"$TEST_ROOT/psql" <<'EOF'
#!/bin/sh
if [ "$1" = --no-psqlrc ] && [ "$2" = --quiet ] && [ "$3" = --set=ON_ERROR_STOP=1 ] && [ "$4" = --file=- ]; then
    cat >"$SQL_CAPTURE"
else
    printf '%s\n' "${QUERY_RESULT-t}"
fi
echo "fixture SQL output that must not leak" >&2
exit "${PSQL_EXIT_CODE:-0}"
EOF
chmod +x "$TEST_ROOT/psql"
export PATH="$TEST_ROOT:$PATH" SQL_CAPTURE="$TEST_ROOT/sql"
export INIT_SQL=$'CREATE SCHEMA "app";\nSELECT \'literal $value; `not a command`\';'
initialize="$REPO_ROOT/Data/postgreSqlDatabases/recipes/azure/bicep/initialize-database.sh"
probe="$REPO_ROOT/Data/postgreSqlDatabases/test/verify-database.sh"

output="$(sh "$initialize" 2>&1)" || fail "initialization failed"
[[ -z "$output" ]] || fail "successful SQL must not print results or SQL"
[[ "$(cat "$SQL_CAPTURE")" == "$INIT_SQL" ]] || fail "SQL must reach psql without shell evaluation"
if output="$(PSQL_EXIT_CODE=1 sh "$initialize" 2>&1)"; then
    fail "SQL failure must fail initialization"
fi
[[ "$output" == "Error: PostgreSQL initSql failed."* ]] || fail "SQL failure must have an explicit error"
[[ "$output" != *"fixture SQL output"* ]] || fail "SQL errors must not leak"

QUERY_RESULT=t sh "$probe" || fail "successful database checks must pass"
for result in f '' garbage; do
    if QUERY_RESULT="$result" sh "$probe" >/dev/null 2>&1; then
        fail "missing prerequisites must fail"
    fi
done
if PSQL_EXIT_CODE=1 sh "$probe" >/dev/null 2>&1; then
    fail "query failures must fail"
fi
echo "PostgreSQL settings and initialization tests passed"
