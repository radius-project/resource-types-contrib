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
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-postgresql-init-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat >"$TEST_ROOT/psql" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$PSQL_CALL_LOG"
cat >"$SQL_CAPTURE"
printf 'SQL output: %s password: %s\n' "$INIT_SQL" "$PGPASSWORD"
printf 'SQL error: %s password: %s\n' "$INIT_SQL" "$PGPASSWORD" >&2
exit "${PSQL_EXIT_CODE:-0}"
EOF
cat >"$TEST_ROOT/tdnf" <<'EOF'
#!/bin/sh
echo "unexpected installation" >"$TDNF_CALL_LOG"
exit 1
EOF
chmod +x "$TEST_ROOT/psql" "$TEST_ROOT/tdnf"
export PATH="$TEST_ROOT:$PATH" SQL_CAPTURE="$TEST_ROOT/sql" PSQL_CALL_LOG="$TEST_ROOT/psql-calls"
export TDNF_CALL_LOG="$TEST_ROOT/tdnf-calls" SQL_EVAL_MARKER="$TEST_ROOT/evaluated"
export PGPASSWORD='fixture-password-must-not-leak'
INIT_SQL="$(cat <<'SQL'
CREATE SCHEMA "app";
SELECT 'literal $value; `touch "$SQL_EVAL_MARKER"`; $(touch "$SQL_EVAL_MARKER"); ${value}; %s';
SQL
)"
export INIT_SQL
printf '%s\n' "$INIT_SQL" >"$TEST_ROOT/expected-sql"
printf '%s\n' --no-psqlrc --quiet --set=ON_ERROR_STOP=1 --file=- >"$TEST_ROOT/expected-args"
initialize="$REPO_ROOT/Data/postgreSqlDatabases/recipes/azure/bicep/initialize-database.sh"

output="$(sh "$initialize" 2>&1)" || fail "initialization failed"
[[ -z "$output" ]] || fail "successful SQL must not print results, SQL, or passwords"
cmp "$TEST_ROOT/expected-sql" "$SQL_CAPTURE" || fail "SQL must reach psql literally through stdin"
cmp "$TEST_ROOT/expected-args" "$PSQL_CALL_LOG" || fail "psql must ignore startup files and stop on SQL errors"
[[ ! -e "$SQL_EVAL_MARKER" ]] || fail "SQL must not run as shell commands"
[[ ! -e "$TDNF_CALL_LOG" ]] || fail "an installed client must not be reinstalled"

if output="$(PSQL_EXIT_CODE=3 sh "$initialize" 2>&1)"; then
    fail "SQL errors must fail initialization"
fi
[[ "$output" == "Error: PostgreSQL initSql failed. Check the SQL and database connection settings." ]] ||
    fail "SQL failure must print only a fixed error, not SQL or passwords"

install_bin="$TEST_ROOT/install-bin"
mkdir "$install_bin"
ln -s "$(command -v cat)" "$install_bin/cat"
export INSTALL_BIN="$install_bin" PSQL_STUB="$TEST_ROOT/psql"
cat >"$install_bin/tdnf" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$TDNF_CALL_LOG"
echo "package output must not leak"
echo "package error must not leak" >&2
if [ "${TDNF_EXIT_CODE:-0}" -ne 0 ]; then
    exit "$TDNF_EXIT_CODE"
fi
/bin/cp "$PSQL_STUB" "$INSTALL_BIN/psql"
EOF
chmod +x "$install_bin/tdnf"
output="$(PATH="$install_bin" /bin/sh "$initialize" 2>&1)" || fail "client installation must allow SQL execution"
[[ -z "$output" ]] || fail "installation and SQL must not print output"
printf '%s\n' install -y '--disablerepo=*' --enablerepo=azurelinux-official-base postgresql >"$TEST_ROOT/expected-install"
cmp "$TEST_ROOT/expected-install" "$TDNF_CALL_LOG" ||
    fail "client installation must use only the official base index and retain signature checks"
cmp "$TEST_ROOT/expected-sql" "$SQL_CAPTURE" || fail "installed client must receive literal SQL"
cmp "$TEST_ROOT/expected-args" "$PSQL_CALL_LOG" || fail "installed client must stop on SQL errors"

rm "$install_bin/psql"
: >"$PSQL_CALL_LOG"
if output="$(PATH="$install_bin" TDNF_EXIT_CODE=1 /bin/sh "$initialize" 2>&1)"; then
    fail "client installation errors must fail initialization"
fi
[[ "$output" == "Error: Could not install the PostgreSQL client." ]] ||
    fail "client installation failure must print only a fixed error"
[[ ! -s "$PSQL_CALL_LOG" ]] || fail "failed installation must not run SQL"
echo "PostgreSQL SQL initialization fixtures passed"
