#!/bin/sh
set -eu
export LC_ALL=C

expected="${1:?Expected transport policy is required}"
test "${CONNECTION_POSTGRESQL_TLS:?Missing TLS projection}" = "$expected" || {
  echo "PostgreSQL TLS projection does not match the requested policy." >&2
  exit 1
}
case "$expected" in
  required|optional|disabled) ;;
  *) echo "Unsupported PostgreSQL test policy." >&2; exit 1 ;;
esac
export PGHOST="${CONNECTION_POSTGRESQL_HOST:?Missing host}"
export PGPORT="${CONNECTION_POSTGRESQL_PORT:?Missing port}"
export PGDATABASE="${CONNECTION_POSTGRESQL_DATABASE:?Missing database}"
export PGUSER="${CONNECTION_POSTGRESQL_USERNAME:?Missing username}"
export PGPASSWORD="${CONNECTION_POSTGRESQL_PASSWORD:?Missing password}"
export PGCONNECT_TIMEOUT=5 PGOPTIONS='-c statement_timeout=5000'
unset PGSERVICE PGSERVICEFILE PGHOSTADDR
case "$PGHOST" in
  /*|'') echo "PostgreSQL probes require a TCP hostname." >&2; exit 1 ;;
esac

query() {
  PGSSLMODE="$1" timeout 10 psql -X -w -At -v ON_ERROR_STOP=1 \
    -c 'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()'
}
expect_success() {
  attempt=0
  until result=$(query "$1" 2>/dev/null); do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      echo "PostgreSQL $1 TCP query failed after bounded retries; inspect server startup, certificates and endpoint." >&2
      exit 1
    fi
    sleep 2
  done
  test "$result" = "$2" || { echo "Unexpected pg_stat_ssl result for $1." >&2; exit 1; }
}

expect_rejection() {
  attempt=0
  while true; do
    if result=$(query "$1" 2>&1); then
      echo "PostgreSQL unexpectedly accepted $1; expected rejection: $2." >&2
      exit 1
    fi
    if printf '%s\n' "$result" | grep -Eq "$2"; then return; fi
    attempt=$((attempt + 1))
    # Service endpoints can briefly lag a completed pod rollout.
    if [ "$attempt" -ge 30 ] || ! printf '%s\n' "$result" |
        grep -Eq 'timeout expired|Connection refused|server closed the connection unexpectedly|Connection reset by peer'; then
      echo "PostgreSQL $1 failed for an unrelated reason; expected rejection: $2." >&2
      exit 1
    fi
    sleep 2
  done
}

case "$expected" in
  required)
    expect_success require t
    expect_rejection disable 'pg_hba.conf rejects connection .*no encryption'
    ;;
  optional)
    expect_success require t
    expect_success disable f
    ;;
  disabled)
    expect_success disable f
    expect_rejection require 'server does not support SSL, but SSL was required'
    ;;
esac

if [ "$expected" != disabled ] && [ -n "${PGSSLROOTCERT:-}" ]; then
  expect_success verify-full t
  if [ -n "${PGSSLUNTRUSTEDROOTCERT:-}" ]; then
    PGSSLROOTCERT="$PGSSLUNTRUSTEDROOTCERT" expect_rejection verify-full 'certificate verify failed'
    address=$(getent hosts "$PGHOST" | awk 'NR == 1 {print $1}')
    test -n "$address"
    PGHOSTADDR="$address" PGHOST=not-in-certificate.invalid \
      expect_rejection verify-full 'does not match host name'
  fi
fi
echo "PostgreSQL TCP policy verified: $expected"
