#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/psql" <<'EOF'
#!/bin/sh
if [ "${TLS_FAIL:-0}" = 1 ]; then
    echo 'connection timed out' >&2
    exit 1
fi
if [ "$PGHOST" = wrong-postgresql.invalid ]; then
    [ "${ACCEPT_WRONG_HOST:-0}" = 1 ] && { echo t; exit 0; }
    echo 'server certificate does not match host name' >&2
    exit 1
fi
if [ "$PGSSLROOTCERT" = /tmp/postgresql-wrong-ca.crt ]; then
    [ "${ACCEPT_WRONG_CA:-0}" = 1 ] && { echo t; exit 0; }
    echo 'certificate verify failed' >&2
    exit 1
fi
if [ "$PGPASSWORD" = incorrect-test-password ]; then
    echo 'password authentication failed' >&2
    exit 1
fi
if [ "$PGSSLMODE" = disable ]; then
    case "${PLAINTEXT_RESULT:-reject}" in
        reject) echo 'pg_hba.conf rejects connection for host, no encryption' >&2; exit 1 ;;
        auth) echo 'password authentication failed' >&2; exit 1 ;;
        timeout) echo 'connection timed out' >&2; exit 1 ;;
        allow) echo f ;;
    esac
else
    echo "${TLS_RESULT:-t}"
fi
EOF
printf '#!/bin/sh\necho "10.0.0.1 postgresql"\n' >"$tmp/bin/getent"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/sleep"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export CONNECTION_POSTGRESQL_HOST=postgresql.ns.svc.cluster.local
export CONNECTION_POSTGRESQL_PORT=5432 CONNECTION_POSTGRESQL_DATABASE=appdb
export CONNECTION_POSTGRESQL_USERNAME=radadmin CONNECTION_POSTGRESQL_PASSWORD=test-password

probe() {
    sh "$root/Data/postgreSqlDatabases/test/verify-transport.sh" "$1" >"$tmp/output" 2>&1
}
export CONNECTION_POSTGRESQL_TLS=required
probe required
export CONNECTION_POSTGRESQL_TLS=optional
PLAINTEXT_RESULT=allow probe optional
export CONNECTION_POSTGRESQL_TLS=required
for invalid in allow auth timeout; do
    if PLAINTEXT_RESULT="$invalid" probe required; then
        echo "Error: required probe accepted plaintext result $invalid." >&2
        exit 1
    fi
done
if TLS_RESULT=f probe required || TLS_FAIL=1 probe required || probe optional ||
    ACCEPT_WRONG_HOST=1 probe required || ACCEPT_WRONG_CA=1 probe required; then
    echo "Error: probe accepted failed TLS or incorrect connection projection." >&2
    exit 1
fi
export CONNECTION_POSTGRESQL_TLS=optional
if probe optional; then
    echo "Error: optional probe accepted rejected plaintext." >&2
    exit 1
fi
echo "PostgreSQL transport probe tests passed."

fixture="$tmp/repo"
mkdir -p "$fixture/.github/scripts" "$fixture/Data/postgreSqlDatabases/"{test,recipes/kubernetes/{bicep,terraform}}
cp "$root/.github/scripts/"{test-recipe.sh,test-recipe-pack-entry.sh,lib-recipe-test.sh} "$fixture/.github/scripts/"
touch "$fixture/Data/postgreSqlDatabases/recipes/kubernetes/bicep/recipe.bicep" \
    "$fixture/Data/postgreSqlDatabases/recipes/kubernetes/terraform/main.tf" \
    "$fixture/Data/postgreSqlDatabases/test/app.bicep"
export DISPATCH_LOG="$tmp/dispatch"
cat >"$fixture/Data/postgreSqlDatabases/test/test-kubernetes.sh" <<'EOF'
#!/bin/bash
echo "$*" >>"$DISPATCH_LOG"
exit "${LIFECYCLE_STATUS:-0}"
EOF
cat >"$tmp/bin/rad" <<'EOF'
#!/bin/bash
case "$1 $2" in
    "workspace switch") exit 0 ;;
    "env show") echo '{"id":"/planes/radius/local/resourcegroups/default/providers/Radius.Core/environments/isolated","properties":{"providers":{"kubernetes":{"namespace":"isolated"}}}}' ;;
    *) echo "Error: unexpected rad invocation in transport dispatch test." >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/rad"
(
    cd "$fixture"
    unset RTC_LIB_RECIPE_TEST_SOURCED RADIUS_WORKSPACE_OVERRIDE RADIUS_ENVIRONMENT_OVERRIDE
    export KUBERNETES_WORKSPACE_NAME=test-ws
    for kind in bicep terraform; do
        bash .github/scripts/test-recipe.sh "Data/postgreSqlDatabases/recipes/kubernetes/$kind" isolated
    done
    bash .github/scripts/test-recipe-pack-entry.sh Data/postgreSqlDatabases test-ws isolated verify-postgresql-transport
    if LIFECYCLE_STATUS=1 bash .github/scripts/test-recipe-pack-entry.sh \
        Data/postgreSqlDatabases test-ws isolated verify-postgresql-transport; then
        echo "Error: dispatcher ignored the failed PostgreSQL lifecycle." >&2
        exit 1
    fi
)
diff -u <(printf 'test-ws isolated bicep\ntest-ws isolated terraform\ntest-ws isolated bicep\ntest-ws isolated bicep\n') "$DISPATCH_LOG"
echo "PostgreSQL recipe dispatch tests passed."
