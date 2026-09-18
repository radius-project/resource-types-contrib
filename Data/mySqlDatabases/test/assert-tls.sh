#!/bin/sh
# Shared by the Radius client container and the Docker image matrix.
set -eu

for tool in mysql timeout awk sed grep; do command -v "$tool" >/dev/null; done
: "${MYSQL_HOST:?}" "${MYSQL_PORT:?}" "${MYSQL_USER:?}" "${MYSQL_DB:?}" "${MYSQL_PASSWORD:?}"
case "${MYSQL_TLS_POLICY:?}" in
    omitted|required) expected_transport=1 ;;
    optional) expected_transport=0 ;;
    *) echo "Unknown MySQL TLS test policy" >&2; exit 1 ;;
esac

export MYSQL_PWD="$MYSQL_PASSWORD"
attempts="${MYSQL_TEST_ATTEMPTS:-30}"
delay="${MYSQL_TEST_DELAY:-2}"
case "$attempts" in ''|*[!0-9]*|0) echo "Invalid readiness attempt limit" >&2; exit 1 ;; esac

mysql_query() {
    mode="$1"
    query="$2"
    shift 2
    if [ "$mode" = DISABLED ]; then
        # Isolated test only: RSA password exchange avoids relying on a cached
        # caching_sha2_password login. This does not authenticate the server.
        set -- --get-server-public-key
    fi
    timeout 10 mysql --protocol=TCP --connect-timeout=5 \
        --host="$MYSQL_HOST" --port="$MYSQL_PORT" --user="$MYSQL_USER" \
        --database="$MYSQL_DB" --batch --skip-column-names \
        --ssl-mode="$mode" --execute="$query" "$@"
}

wait_for_mysql() {
    attempt=0
    while ! response=$(mysql_query "$1" "$2" 2>/dev/null); do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$attempts" ]; then
            echo "MySQL $1 TCP readiness failed after $attempt attempts (connection, authentication, or TLS failure)" >&2
            return 1
        fi
        sleep "$delay"
    done
    printf '%s\n' "$response"
}

tls_query="SELECT @@GLOBAL.require_secure_transport; SHOW SESSION STATUS LIKE 'Ssl_cipher';"
if [ "$expected_transport" = 0 ]; then
    # Probe plaintext before any TLS login can populate the authentication cache.
    plaintext=$(wait_for_mysql DISABLED "SHOW SESSION STATUS LIKE 'Ssl_cipher';")
    if ! encrypted=$(mysql_query REQUIRED "$tls_query" 2>/dev/null); then
        echo "MySQL accepts plaintext TCP but its TLS TCP connection failed" >&2
        exit 1
    fi
else
    encrypted=$(wait_for_mysql REQUIRED "$tls_query")
fi

setting=$(printf '%s\n' "$encrypted" | sed -n '1p')
cipher=$(printf '%s\n' "$encrypted" | awk -F '\t' '$1 == "Ssl_cipher" {print $2}')
if [ "$setting" != "$expected_transport" ] || [ -z "$cipher" ]; then
    echo "MySQL TLS assertion failed: expected secure transport=$expected_transport and a nonempty session cipher" >&2
    echo "Effective secure transport: $setting; session cipher present: ${cipher:+yes}" >&2
    exit 1
fi

if [ "$expected_transport" = 0 ]; then
    # Require the status row, not just an empty query result.
    if ! printf '%s\n' "$plaintext" | awk -F '\t' '
        $1 == "Ssl_cipher" && NF == 2 && $2 == "" {ok=1}
        END {exit !ok}
    '; then
        echo "MySQL optional policy did not return an empty plaintext session cipher" >&2
        exit 1
    fi
elif plaintext=$(mysql_query DISABLED "SHOW SESSION STATUS LIKE 'Ssl_cipher';" 2>&1); then
    echo "MySQL accepted plaintext TCP while secure transport is required" >&2
    exit 1
else
    if ! printf '%s\n' "$plaintext" | grep -Eq '^ERROR 3159 \(HY000\):'; then
        echo "MySQL plaintext TCP failed without the expected secure-transport rejection (3159)" >&2
        exit 1
    fi
fi

unset MYSQL_PWD
echo "MySQL $MYSQL_TLS_POLICY policy: TLS cipher, effective transport setting, and plaintext behavior validated"
