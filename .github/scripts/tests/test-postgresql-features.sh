#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
printf 'public-test-ca\n' >"$tmp/ca.crt"
export FEATURE_QUERY_LOG="$tmp/queries" FEATURE_MODE_LOG="$tmp/modes"
cat >"$tmp/bin/psql" <<'EOF'
#!/bin/sh
printf '%s\n' "$PGSSLMODE" >>"$FEATURE_MODE_LOG"
printf '%s\n' "$*" >>"$FEATURE_QUERY_LOG"
if [ "$PGSSLMODE" = disable ]; then
    if [ "${PLAINTEXT_ACCEPTED:-0}" != 0 ]; then
        printf '1\n'
        exit 0
    fi
    if [ "${PLAINTEXT_OTHER_ERROR:-0}" != 0 ]; then
        printf 'psql: error: connection failed with password: %s\n' "$PGPASSWORD" >&2
        exit 1
    fi
    printf 'psql: error: connection to server failed: FATAL:  no pg_hba.conf entry for host "10.0.0.1", user "radadmin", database "appdb", no encryption\n' >&2
    exit 1
fi
case "$*" in
    *pg_stat_ssl*) result="${TLS_RESULT:-t}"; failure="${TLS_FAILURE:-0}" ;;
    *pg_settings*) result="${SETTINGS_RESULT:-1000|5432|2}"; failure="${SETTINGS_FAILURE:-0}" ;;
    *azure.extensions*) result="${ALLOWLIST_RESULT:-pg_trgm, btree_gin}"; failure="${ALLOWLIST_FAILURE:-0}" ;;
    *rtc_nightly.seed*) result="${SEED_RESULT:-t}"; failure="${SEED_FAILURE:-0}" ;;
    *) echo "Unexpected query" >&2; exit 1 ;;
esac
if [ "$failure" != 0 ]; then
    printf 'SQL error containing password: %s\n' "$PGPASSWORD" >&2
    exit 1
fi
printf '%s\n' "$result"
EOF
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/sleep"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export CONNECTION_POSTGRESQL_HOST=postgresql.example.test
export CONNECTION_POSTGRESQL_PORT=5432 CONNECTION_POSTGRESQL_DATABASE=appdb
export CONNECTION_POSTGRESQL_USERNAME=radadmin CONNECTION_POSTGRESQL_PASSWORD=must-not-leak
probe="$root/Data/postgreSqlDatabases/test/verify-features.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

sh "$probe" azure true "$tmp/ca.crt" >"$tmp/output"
mode_count="$(wc -l <"$FEATURE_MODE_LOG")"
verify_full_count="$(grep -cx verify-full "$FEATURE_MODE_LOG")"
disable_count="$(grep -cx disable "$FEATURE_MODE_LOG")"
[[ "$mode_count" == 5 ]] || fail "Azure must run TLS, settings, allow-list, plaintext refusal, and seed checks"
[[ "$verify_full_count" == 4 ]] || fail "all four SQL queries must verify server identity"
[[ "$disable_count" == 1 ]] || fail "Azure must probe plaintext refusal once"
if grep -q 'require_secure_transport' "$FEATURE_QUERY_LOG"; then fail "Azure must not query non-existent require_secure_transport GUC"; fi
grep -q -- '-X -w -At --set=ON_ERROR_STOP=1' "$FEATURE_QUERY_LOG" || fail "SQL errors must stop the probe"

: >"$FEATURE_QUERY_LOG"
: >"$FEATURE_MODE_LOG"
sh "$probe" kubernetes true "$tmp/ca.crt" >"$tmp/output"
grep -q rtc_nightly.seed "$FEATURE_QUERY_LOG" || fail "Bicep must check initialized data"
if grep -q azure.extensions "$FEATURE_QUERY_LOG"; then fail "Kubernetes must not query Azure-only settings"; fi
if grep -vx verify-full "$FEATURE_MODE_LOG"; then fail "Kubernetes must verify server identity on every query"; fi
: >"$FEATURE_QUERY_LOG"
sh "$probe" kubernetes false "$tmp/ca.crt" >"$tmp/output"
if grep -q rtc_nightly.seed "$FEATURE_QUERY_LOG"; then fail "Terraform must not claim initSql support"; fi

for fault in TLS_RESULT=f "SETTINGS_RESULT=1000|6432|1" "ALLOWLIST_RESULT=pg_trgm" SEED_RESULT=f \
    TLS_FAILURE=1 SETTINGS_FAILURE=1 ALLOWLIST_FAILURE=1 PLAINTEXT_ACCEPTED=1 PLAINTEXT_OTHER_ERROR=1 SEED_FAILURE=1; do
    if env "$fault" sh "$probe" azure true "$tmp/ca.crt" >"$tmp/output" 2>&1; then
        fail "$fault must fail the runtime probe"
    fi
    if grep -q must-not-leak "$tmp/output"; then fail "$fault exposed credentials"; fi
done
if sh "$probe" azure true "$tmp/missing-ca" >"$tmp/output" 2>&1; then
    fail "a missing CA bundle must fail, not fall back to unverified TLS"
fi
SETTINGS_RESULT='1000|6432|1' sh "$probe" azure true "$tmp/ca.crt" >"$tmp/output" 2>&1 || true
grep -q "port is '6432', expected '5432'" "$tmp/output" || fail "a mismatch must report the actual port"
grep -q "extension count (pg_trgm, btree_gin) is '1', expected '2'" "$tmp/output" || fail "a mismatch must report every differing value"
ALLOWLIST_RESULT='pg_trgm' PLAINTEXT_ACCEPTED=1 sh "$probe" azure true "$tmp/ca.crt" >"$tmp/output" 2>&1 || true
grep -q "azure.extensions is 'pg_trgm', missing 'btree_gin'" "$tmp/output" || fail "allow-list mismatch must show the list"
grep -q "Azure PostgreSQL accepted an unencrypted connection" "$tmp/output" || fail "plaintext acceptance must be reported"
PLAINTEXT_OTHER_ERROR=1 sh "$probe" azure true "$tmp/ca.crt" >"$tmp/output" 2>&1 || true
grep -q "Plaintext connection failed for a reason other than required TLS" "$tmp/output" || fail "unrelated plaintext errors must not pass as TLS enforcement"
echo "PostgreSQL nightly feature probe tests passed."
