#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$REPO_ROOT/.mysql-shell-tests-$$"
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/repo"
trap 'rm -rf "$TEST_ROOT"' EXIT
export COMMAND_CALLS="$TEST_ROOT/calls"
export PATH="$TEST_ROOT/bin:$PATH"
for recipe in Data/mySqlDatabases/recipes/kubernetes/bicep Data/mySqlDatabases/recipes/azure/bicep Data/widgets/recipes/kubernetes/bicep; do
    mkdir -p "$TEST_ROOT/repo/$recipe" "$TEST_ROOT/repo/${recipe%/recipes/*}/test"
    touch "$TEST_ROOT/repo/$recipe/main.bicep"
    printf 'param password string\n' >"$TEST_ROOT/repo/${recipe%/recipes/*}/test/app.bicep"
done

cat >"$TEST_ROOT/bin/openssl" <<'SH'
#!/bin/bash
printf '%s\n' 'test password with spaces'
SH
cat >"$TEST_ROOT/bin/kubectl" <<'SH'
#!/bin/bash
echo "kubectl $*" >>"$COMMAND_CALLS"
SH
cat >"$TEST_ROOT/bin/rad" <<'SH'
#!/bin/bash
set -eu
action="$1 ${2:-}"
case "$action" in
    "env show")
        echo '{"id":"/planes/radius/local/resourcegroups/default/providers/Radius.Core/environments/default","properties":{"providers":{"kubernetes":{"namespace":"mysql-test-ns"}}}}'
        ;;
    deploy\ *)
        shift 2
        app="" policy="" authored_app="" password_seen=0
        while (($#)); do
            case "$1" in
                --application) app="$2"; shift 2 ;;
                -e) shift 2 ;;
                --parameters)
                    case "$2" in
                        password=*) [[ "$2" == "password=test password with spaces" ]]; password_seen=1 ;;
                        tlsPolicy=*) policy="${2#*=}" ;;
                        applicationName=*) authored_app="${2#*=}" ;;
                        *) exit 20 ;;
                    esac
                    shift 2 ;;
                *) exit 21 ;;
            esac
        done
        [[ "$password_seen" == 1 ]]
        if [[ -n "$policy" ]]; then [[ "$authored_app" == "$app" ]]; fi
        echo "deploy $app ${policy:-single}" >>"$COMMAND_CALLS"
        [[ "${SCENARIO:-}" != deploy-failure || "$policy" != required ]]
        ;;
    "resource show")
        app=""
        while (($#)); do
            if [[ "$1" == --application ]]; then app="$2"; break; fi
            shift
        done
        echo "show $app" >>"$COMMAND_CALLS"
        [[ "${SCENARIO:-}" != show-failure || "$app" != *-required ]] || exit 1
        tls=required
        [[ "$app" != *-optional ]] || tls=optional
        [[ "${SCENARIO:-}" != wrong-default || "$app" != *-omitted ]] || tls=optional
        host=mysql.mysql-test-ns.svc.cluster.local
        [[ "${SCENARIO:-}" != missing-host ]] || host=""
        extra='"password":"never-print-resource-json"'
        [[ "${SCENARIO:-}" != secret-output ]] || extra='"secrets":{"password":"never-print-resource-json"}'
        printf '{"properties":{"host":"%s","port":3306,"database":"appdb","tls":"%s",%s}}\n' "$host" "$tls" "$extra"
        ;;
    "app delete") echo "delete $3" >>"$COMMAND_CALLS" ;;
    "recipe unregister") echo unregister >>"$COMMAND_CALLS" ;;
esac
SH
chmod +x "$TEST_ROOT/bin/"*

run_recipe() {
    : >"$COMMAND_CALLS"
    (
        cd "$TEST_ROOT/repo"
        bash "$REPO_ROOT/.github/scripts/test-recipe.sh" "$1"
    ) >"$TEST_ROOT/output" 2>&1
}
assert_cleanup() {
    diff <(awk '$1=="deploy" {print $2}' "$COMMAND_CALLS") \
         <(awk '$1=="delete" {print $2}' "$COMMAND_CALLS")
    local count
    count=$(grep -c '^deploy ' "$COMMAND_CALLS")
    [[ "$(grep -c '^kubectl delete secrets --all -n mysql-test-ns$' "$COMMAND_CALLS")" == "$count" ]]
    [[ "$(awk '$1=="deploy" {print $2}' "$COMMAND_CALLS" | sort -u | wc -l)" -eq "$count" ]]
    if grep -Eq 'never-print-resource-json|test password with spaces' "$TEST_ROOT/output"; then
        echo "Recipe runner printed credentials" >&2; exit 1
    fi
}
mysql_recipe=Data/mySqlDatabases/recipes/kubernetes/bicep
export SCENARIO=success
run_recipe "$mysql_recipe"
[[ "$(awk '$1=="deploy" {print $3}' "$COMMAND_CALLS" | paste -sd,)" == omitted,required,optional ]]
assert_cleanup

for SCENARIO in deploy-failure show-failure wrong-default missing-host secret-output; do
    export SCENARIO
    if run_recipe "$mysql_recipe"; then echo "Expected failure: $SCENARIO" >&2; exit 1; fi
    assert_cleanup
    if grep -q ' optional$' "$COMMAND_CALLS"; then echo "Runner continued after failure" >&2; exit 1; fi
    if [[ "$SCENARIO" == deploy-failure ]]; then grep -qx unregister "$COMMAND_CALLS"; fi
done
export SCENARIO=success
for recipe in Data/mySqlDatabases/recipes/azure/bicep Data/widgets/recipes/kubernetes/bicep; do
    run_recipe "$recipe"
    [[ "$(grep -c '^deploy ' "$COMMAND_CALLS")" == 1 ]]
    grep -q ' single$' "$COMMAND_CALLS"
    assert_cleanup
done

cat >"$TEST_ROOT/bin/mysql" <<'SH'
#!/bin/bash
set -eu
[[ "$MYSQL_PWD" == "test password with spaces" ]]
[[ " $* " == *" --protocol=TCP "* && " $* " == *" --connect-timeout=5 "* ]]
if [[ " $* " == *" --ssl-mode=REQUIRED "* ]]; then
    echo REQUIRED >>"$COMMAND_CALLS"
    if [[ "$SCENARIO" == readiness-failure ]]; then echo "ERROR 2003: unreachable" >&2; exit 1; fi
    setting=1
    [[ "$MYSQL_TLS_POLICY" != optional ]] || setting=0
    [[ "$SCENARIO" != wrong-setting ]] || setting=9
    printf '%s\n' "$setting"
    if [[ "$SCENARIO" == missing-cipher ]]; then printf 'Ssl_cipher\t\n'; else printf 'Ssl_cipher\tTLS_AES_256_GCM_SHA384\n'; fi
else
    [[ " $* " == *" --get-server-public-key "* ]]
    echo DISABLED >>"$COMMAND_CALLS"
    case "$SCENARIO" in
        accepts-plaintext) printf 'Ssl_cipher\t\n' ;;
        auth-failure) echo 'ERROR 1045 (28000): authentication failed' >&2; exit 1 ;;
        network-failure) echo 'ERROR 2003 (HY000): network failed' >&2; exit 1 ;;
        misleading-3159) echo 'ERROR 1045 (28000): user 3159 failed' >&2; exit 1 ;;
        missing-status) : ;;
        plaintext-cipher) printf 'Ssl_cipher\tunexpected\n' ;;
        *)
            if [[ "$MYSQL_TLS_POLICY" == optional ]]; then
                printf 'Ssl_cipher\t\n'
            else
                echo 'ERROR 3159 (HY000): Connections using insecure transport are prohibited while --require_secure_transport=ON.' >&2
                exit 1
            fi ;;
    esac
fi
SH
chmod +x "$TEST_ROOT/bin/mysql"
export MYSQL_HOST=mysql MYSQL_PORT=3306 MYSQL_USER=radadmin MYSQL_DB=appdb
export MYSQL_PASSWORD='test password with spaces' MYSQL_TEST_ATTEMPTS=2 MYSQL_TEST_DELAY=0
for MYSQL_TLS_POLICY in omitted required optional; do
    export MYSQL_TLS_POLICY
    : >"$COMMAND_CALLS"
    SCENARIO=success bash "$REPO_ROOT/Data/mySqlDatabases/test/assert-tls.sh" >/dev/null
    expected_order=$'REQUIRED\nDISABLED'
    [[ "$MYSQL_TLS_POLICY" != optional ]] || expected_order=$'DISABLED\nREQUIRED'
    [[ "$(cat "$COMMAND_CALLS")" == "$expected_order" ]]
    for SCENARIO in readiness-failure wrong-setting missing-cipher auth-failure network-failure misleading-3159; do
        export SCENARIO
        : >"$COMMAND_CALLS"
        if bash "$REPO_ROOT/Data/mySqlDatabases/test/assert-tls.sh" >"$TEST_ROOT/output" 2>&1; then
            echo "Expected probe failure: $MYSQL_TLS_POLICY/$SCENARIO" >&2; exit 1
        fi
        if grep -q 'test password with spaces' "$TEST_ROOT/output"; then
            echo "Probe printed credentials" >&2; exit 1
        fi
        [[ "$(wc -l <"$COMMAND_CALLS")" -le 2 ]]
    done
done
for SCENARIO in accepts-plaintext missing-status plaintext-cipher; do
    export SCENARIO
    MYSQL_TLS_POLICY=required
    [[ "$SCENARIO" == accepts-plaintext ]] || MYSQL_TLS_POLICY=optional
    export MYSQL_TLS_POLICY
    if bash "$REPO_ROOT/Data/mySqlDatabases/test/assert-tls.sh" >"$TEST_ROOT/output" 2>&1; then
        echo "Expected plaintext assertion failure: $SCENARIO" >&2; exit 1
    fi
done
echo "MySQL TLS shell regression tests passed"
