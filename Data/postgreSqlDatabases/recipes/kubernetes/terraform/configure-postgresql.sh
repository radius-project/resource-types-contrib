#!/bin/sh
set -eu

case "${POSTGRES_TLS:-required}" in
  required) ssl=on; plaintext_auth=reject ;;
  optional) ssl=on; plaintext_auth=scram-sha-256 ;;
  disabled) ssl=off; plaintext_auth=scram-sha-256 ;;
  *) echo "Unsupported POSTGRES_TLS policy; use required, optional, or disabled." >&2; exit 1 ;;
esac

umask 077
# A surviving tmpfs can contain postgres-owned files; avoid sticky-directory
# protections preventing root from refreshing them on container restart.
chmod 755 /postgres-config
printf '%s\n' 'local all all trust' > /postgres-config/pg_hba.conf
if [ "$ssl" = on ]; then
  test -s /tls-source/tls.crt && test -s /tls-source/tls.key || {
    echo "PostgreSQL TLS requires a nonempty tls.crt and tls.key in the configured operator TLS Secret." >&2
    exit 1
  }
  cp /tls-source/tls.crt /postgres-config/server.crt
  cp /tls-source/tls.key /postgres-config/server.key
  chown postgres:postgres /postgres-config/server.crt /postgres-config/server.key
  chmod 600 /postgres-config/server.key
  printf '%s\n' 'hostssl all all all scram-sha-256' >> /postgres-config/pg_hba.conf
  set -- -c ssl_cert_file=/postgres-config/server.crt -c ssl_key_file=/postgres-config/server.key
else
  set --
fi
printf 'hostnossl all all all %s\n' "$plaintext_auth" >> /postgres-config/pg_hba.conf
chown postgres:postgres /postgres-config/pg_hba.conf

# The upstream entrypoint initializes through Unix sockets and drops privileges.
exec /usr/local/bin/docker-entrypoint.sh postgres \
  -c "ssl=$ssl" -c hba_file=/postgres-config/pg_hba.conf \
  -c password_encryption=scram-sha-256 "$@"
