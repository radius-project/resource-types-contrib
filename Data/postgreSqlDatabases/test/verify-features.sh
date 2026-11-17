#!/bin/sh
set -eu

platform="${1:?expected azure or kubernetes}"
check_initialization="${2:?expected true or false}"
case "$platform:$check_initialization" in
    azure:true|kubernetes:true|kubernetes:false) ;;
    *) echo "Error: Invalid PostgreSQL feature probe mode." >&2; exit 1 ;;
esac

export PGHOST="$CONNECTION_POSTGRESQL_HOST" PGPORT="$CONNECTION_POSTGRESQL_PORT"
export PGUSER="$CONNECTION_POSTGRESQL_USERNAME" PGDATABASE="$CONNECTION_POSTGRESQL_DATABASE"
export PGPASSWORD="$CONNECTION_POSTGRESQL_PASSWORD" PGCONNECT_TIMEOUT=5
export PGOPTIONS='-c statement_timeout=5000' PGSSLMODE=verify-full
export PGSSLROOTCERT="${3:-/etc/ssl/certs/ca-certificates.crt}"
test -s "$PGSSLROOTCERT" || {
    echo "Error: PostgreSQL feature checks require a trusted public CA bundle." >&2
    exit 1
}

query() {
    timeout 10 psql -X -w -At --set=ON_ERROR_STOP=1 -c "$1" 2>/dev/null
}

attempt=0
until result=$(query 'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()'); do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 12 ]; then
        echo "Error: PostgreSQL verified TLS connection failed within the retry limit." >&2
        exit 1
    fi
    sleep 2
done
test "$result" = t || {
    echo "Error: PostgreSQL feature checks require an encrypted connection." >&2
    exit 1
}

if ! result=$(query "SELECT
    (SELECT setting FROM pg_settings WHERE name = 'log_min_duration_statement') = '1000'
    AND (SELECT setting FROM pg_settings WHERE name = 'port') = '5432'
    AND (SELECT count(*) FROM pg_extension WHERE extname IN ('pg_trgm', 'btree_gin')) = 2"); then
    echo "Error: Could not query PostgreSQL extensions and server settings." >&2
    exit 1
fi
test "$result" = t || {
    echo "Error: PostgreSQL extensions, application settings, or protected port differ from the expected state." >&2
    exit 1
}

if [ "$platform" = azure ]; then
    if ! result=$(query "SELECT
        ARRAY['pg_trgm', 'btree_gin'] <@ regexp_split_to_array(lower(current_setting('azure.extensions')), '\s*,\s*')
        AND current_setting('require_secure_transport') = 'on'"); then
        echo "Error: Could not query the Azure PostgreSQL allow-list and transport policy." >&2
        exit 1
    fi
    test "$result" = t || {
        echo "Error: Azure PostgreSQL extension allow-list or required TLS policy differs from the expected state." >&2
        exit 1
    }
fi

if [ "$check_initialization" = true ]; then
    if ! result=$(query "SELECT count(*) = 1 AND min(value) = 'nightly-seed' FROM rtc_nightly.seed WHERE id = 1"); then
        echo "Error: Could not query the PostgreSQL initialization schema and table." >&2
        exit 1
    fi
    test "$result" = t || {
        echo "Error: PostgreSQL initialization seed data differs from the expected state." >&2
        exit 1
    }
fi
echo "PostgreSQL extensions, server settings, and supported initialization checks passed over verified TLS."
