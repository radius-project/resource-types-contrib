#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir "$TEMP/bin"
cat > "$TEMP/bin/psql" <<'EOF'
#!/bin/sh
set -eu
test "$PGPASSWORD" = fixture-password
test "$PGCONNECT_TIMEOUT" = 5
test "$PGOPTIONS" = '-c statement_timeout=5000'
test "$*" = '-X -w -At -v ON_ERROR_STOP=1 -c SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()'
echo "$PGSSLMODE" >> "$CALLS"
if [ "${QUERY_FAIL:-0}" = 1 ]; then echo 'connection refused' >&2; exit 2; fi
case "$PGSSLMODE" in
  require)
    if [ "$SERVER_POLICY" = disabled ]; then
      echo 'server does not support SSL, but SSL was required' >&2; exit 2
    fi
    printf '%s\n' "${TLS_RESULT-t}"
    ;;
  disable)
    case "${PLAINTEXT_RESULT:-$SERVER_POLICY}" in
      required) echo 'pg_hba.conf rejects connection for host "127.0.0.1", user "radadmin", database "appdb", no encryption' >&2; exit 2 ;;
      password) echo 'password authentication failed' >&2; exit 2 ;;
      dns) echo 'could not translate host name' >&2; exit 2 ;;
      timeout) exit 124 ;;
      transient)
        if [ "$(grep -c disable "$CALLS")" -eq 1 ]; then echo 'timeout expired' >&2; exit 2; fi
        echo 'pg_hba.conf rejects connection for host "127.0.0.1", no encryption' >&2; exit 2 ;;
      unreachable) echo 'timeout expired' >&2; exit 2 ;;
      t) echo t ;;
      *) echo f ;;
    esac
    ;;
  verify-full)
    if [ "${VERIFY_FAIL:-0}" = 1 ]; then exit 2; fi
    if [ "${PGSSLROOTCERT:-}" = /untrusted ]; then echo 'certificate verify failed' >&2; exit 2; fi
    if [ "$PGHOST" = not-in-certificate.invalid ]; then echo 'server certificate does not match host name' >&2; exit 2; fi
    echo t
    ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$TEMP/bin/sleep"
printf '#!/bin/sh\necho "127.0.0.1 db"\n' > "$TEMP/bin/getent"
chmod +x "$TEMP/bin/"*
export PATH="$TEMP/bin:$PATH" CALLS="$TEMP/calls"
export CONNECTION_POSTGRESQL_HOST=db CONNECTION_POSTGRESQL_PORT=5432
export CONNECTION_POSTGRESQL_DATABASE=appdb CONNECTION_POSTGRESQL_USERNAME=radadmin
export CONNECTION_POSTGRESQL_PASSWORD=fixture-password
probe="$ROOT/Data/postgreSqlDatabases/test/verify-transport.sh"
for policy in required optional disabled; do
    CONNECTION_POSTGRESQL_TLS="$policy" SERVER_POLICY="$policy" sh "$probe" "$policy" ||
        fail "valid $policy policy"
done
export CONNECTION_POSTGRESQL_TLS=required SERVER_POLICY=required
PGSSLROOTCERT=/trusted PGSSLUNTRUSTEDROOTCERT=/untrusted sh "$probe" required ||
    fail "CA and hostname verification"
for result in optional t password dns timeout; do
    if PLAINTEXT_RESULT="$result" sh "$probe" required 2>/dev/null; then
        fail "required accepted incorrect plaintext result: $result"
    fi
done
for result in '' f NULL garbage; do
    if TLS_RESULT="$result" sh "$probe" required 2>/dev/null; then fail "bad SSL result"; fi
done
if CONNECTION_POSTGRESQL_TLS=disabled SERVER_POLICY=optional sh "$probe" disabled 2>/dev/null; then
    fail "disabled accepted TLS"
fi
if CONNECTION_POSTGRESQL_TLS=optional PLAINTEXT_RESULT=required sh "$probe" optional 2>/dev/null; then
    fail "optional rejected plaintext"
fi
if sh "$probe" optional 2>/dev/null; then fail "incorrect connection projection"; fi
if CONNECTION_POSTGRESQL_HOST=/tmp sh "$probe" required 2>/dev/null; then fail "socket host"; fi
if PGSSLROOTCERT=/trusted VERIFY_FAIL=1 sh "$probe" required 2>/dev/null; then fail "unverified identity"; fi
: > "$CALLS"
if QUERY_FAIL=1 sh "$probe" required 2>/dev/null; then fail "unreachable server"; fi
[[ "$(wc -l < "$CALLS")" -eq 30 ]] || fail "retry bound"
: > "$CALLS"
PLAINTEXT_RESULT=transient sh "$probe" required || fail "transient endpoint error"
[[ "$(grep -c disable "$CALLS")" -eq 2 ]] || fail "negative retry did not reach policy rejection"
: > "$CALLS"
if PLAINTEXT_RESULT=unreachable sh "$probe" required 2>/dev/null; then fail "unreachable is not policy rejection"; fi
[[ "$(grep -c disable "$CALLS")" -eq 30 ]] || fail "negative retry bound"

diff -u "$ROOT/Data/postgreSqlDatabases/recipes/kubernetes/"{bicep,terraform}/configure-postgresql.sh ||
    fail "the independently packaged startup scripts must agree"
sh -n "$ROOT/Data/postgreSqlDatabases/recipes/kubernetes/bicep/configure-postgresql.sh"
echo "PostgreSQL transport unit tests passed"
