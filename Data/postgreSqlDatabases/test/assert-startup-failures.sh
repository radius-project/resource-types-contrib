#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEMP="$(mktemp -d)"
name="postgresql-tls-negative-$$"
cleanup() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    rm -rf "$TEMP"
}
trap cleanup EXIT

for recipe in bicep terraform; do
    for policy in omitted required optional; do
        for material in missing malformed; do
            args=()
            [[ "$policy" == omitted ]] || args=(-e "POSTGRES_TLS=$policy")
            setup='mkdir -p /postgres-config; chmod 1777 /postgres-config'
            setup+='; touch /postgres-config/pg_hba.conf /postgres-config/server.crt /postgres-config/server.key'
            setup+='; chown postgres:postgres /postgres-config/pg_hba.conf /postgres-config/server.crt /postgres-config/server.key'
            setup+='; chmod 600 /postgres-config/pg_hba.conf /postgres-config/server.crt /postgres-config/server.key'
            if [[ "$material" == malformed ]]; then
                setup+='; mkdir /tls-source; printf invalid > /tls-source/tls.crt; printf invalid > /tls-source/tls.key'
            fi
            if timeout 60 docker run --rm --name "$name" -i \
                --tmpfs /postgres-config --tmpfs /var/lib/postgresql/data \
                -e POSTGRES_PASSWORD=fixture-password "${args[@]}" \
                --entrypoint /bin/sh postgres:16-alpine -ec "$setup; exec sh -s" \
                < "$ROOT/Data/postgreSqlDatabases/recipes/kubernetes/$recipe/configure-postgresql.sh" \
                > "$TEMP/startup.log" 2>&1; then
                echo "Error: $recipe $policy accepted $material TLS material." >&2
                exit 1
            else
                status=$?
            fi
            [[ "$status" != 124 ]] || {
                echo "Error: $recipe $policy startup timed out instead of exiting." >&2
                exit 1
            }
            if [[ "$material" == missing ]]; then
                reason='PostgreSQL TLS requires a nonempty tls.crt and tls.key'
            else
                reason='could not load server certificate|could not load private key'
            fi
            grep -Eq "$reason" "$TEMP/startup.log" || {
                echo "Error: $recipe $policy failed for an unrelated reason." >&2
                cat "$TEMP/startup.log" >&2
                exit 1
            }
            docker rm -f "$name" >/dev/null 2>&1 || true
        done
    done
done
echo "PostgreSQL startup rejects missing/malformed certificates in both recipes"
