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
case "$*" in
    *pg_stat_ssl*) result="${TLS_RESULT:-t}"; failure="${TLS_FAILURE:-0}" ;;
    *pg_settings*) result="${SETTINGS_RESULT:-t}"; failure="${SETTINGS_FAILURE:-0}" ;;
    *azure.extensions*) result="${ALLOWLIST_RESULT:-t}"; failure="${ALLOWLIST_FAILURE:-0}" ;;
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
[[ "$(wc -l <"$FEATURE_MODE_LOG")" == 4 ]] || fail "Azure must query TLS, settings, allow-list, and seed"
if grep -vx verify-full "$FEATURE_MODE_LOG"; then fail "every query must verify server identity"; fi
grep -q 'require_secure_transport' "$FEATURE_QUERY_LOG" || fail "Azure must check its effective transport policy"
grep -q -- '-X -w -At --set=ON_ERROR_STOP=1' "$FEATURE_QUERY_LOG" || fail "SQL errors must stop the probe"

: >"$FEATURE_QUERY_LOG"
sh "$probe" kubernetes true "$tmp/ca.crt" >"$tmp/output"
grep -q rtc_nightly.seed "$FEATURE_QUERY_LOG" || fail "Bicep must check initialized data"
if grep -q azure.extensions "$FEATURE_QUERY_LOG"; then fail "Kubernetes must not query Azure-only settings"; fi
: >"$FEATURE_QUERY_LOG"
sh "$probe" kubernetes false "$tmp/ca.crt" >"$tmp/output"
if grep -q rtc_nightly.seed "$FEATURE_QUERY_LOG"; then fail "Terraform must not claim initSql support"; fi

for fault in TLS_RESULT=f SETTINGS_RESULT=f ALLOWLIST_RESULT=f SEED_RESULT=f \
    TLS_FAILURE=1 SETTINGS_FAILURE=1 ALLOWLIST_FAILURE=1 SEED_FAILURE=1; do
    if env "$fault" sh "$probe" azure true "$tmp/ca.crt" >"$tmp/output" 2>&1; then
        fail "$fault must fail the runtime probe"
    fi
    if grep -q must-not-leak "$tmp/output"; then fail "$fault exposed credentials"; fi
done
if sh "$probe" azure true "$tmp/missing-ca" >"$tmp/output" 2>&1; then
    fail "a missing CA bundle must fail, not fall back to unverified TLS"
fi
echo "PostgreSQL nightly feature probe tests passed."
