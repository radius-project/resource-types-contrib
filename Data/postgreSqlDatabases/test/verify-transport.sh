#!/bin/sh
set -eu
error_file="$(mktemp)"
trap 'rm -f "$error_file"' EXIT

expected="${1:?expected TLS policy is required}"
test "$CONNECTION_POSTGRESQL_TLS" = "$expected" || {
    echo "Error: CONNECTION_POSTGRESQL_TLS does not match the deployed policy." >&2
    exit 1
}

export PGHOST="$CONNECTION_POSTGRESQL_HOST" PGPORT="$CONNECTION_POSTGRESQL_PORT"
export PGUSER="$CONNECTION_POSTGRESQL_USERNAME" PGDATABASE="$CONNECTION_POSTGRESQL_DATABASE"
export PGPASSWORD="$CONNECTION_POSTGRESQL_PASSWORD" PGCONNECT_TIMEOUT=5
export PGOPTIONS='-c statement_timeout=5000' PGSSLMODE=require
export PGSSLROOTCERT=/tmp/postgresql-test-ca.crt LC_ALL=C
query='SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()'

attempt=0
until result=$(timeout 10 psql -X -w -Atc "$query" 2>"$error_file"); do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 12 ]; then
        echo "Error: TLS PostgreSQL query did not succeed within the retry limit." >&2
        cat "$error_file" >&2
        exit 1
    fi
    sleep 2
done
test "$result" = t
test "$(PGSSLMODE=verify-full timeout 10 psql -X -w -Atc "$query")" = t

if result=$(PGSSLMODE=disable timeout 10 psql -X -w -Atc "$query" 2>"$error_file"); then
    test "$expected" = optional && test "$result" = f || {
        echo "Error: Required PostgreSQL policy accepted plaintext." >&2
        exit 1
    }
else
    if [ "$expected" != required ] ||
        ! grep -Eq 'pg_hba.conf rejects connection.*no encryption' "$error_file"; then
        echo "Error: Plaintext query failed for a reason other than the required transport policy." >&2
        cat "$error_file" >&2
        exit 1
    fi
fi

# Same endpoint and credentials: isolate hostname and CA verification failures.
address=$(getent hosts "$PGHOST" | awk 'NR == 1 { print $1 }')
test -n "$address"
if PGHOST=wrong-postgresql.invalid PGHOSTADDR="$address" PGSSLMODE=verify-full \
    timeout 10 psql -X -w -Atc "$query" 2>"$error_file"; then
    echo "Error: Client accepted a certificate for the wrong hostname." >&2
    exit 1
fi
grep -q 'does not match host name' "$error_file"
if PGSSLROOTCERT=/tmp/postgresql-wrong-ca.crt PGSSLMODE=verify-full \
    timeout 10 psql -X -w -Atc "$query" 2>"$error_file"; then
    echo "Error: Client accepted an untrusted certificate." >&2
    exit 1
fi
grep -q 'certificate verify failed' "$error_file"
if PGPASSWORD=incorrect-test-password timeout 10 psql -X -w -Atc "$query" 2>"$error_file"; then
    echo "Error: PostgreSQL accepted an incorrect password." >&2
    exit 1
fi
grep -q 'password authentication failed' "$error_file"
echo "PostgreSQL $expected transport and certificate verification passed."
