#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$1 $2" in
    "deploy "*)
        shift
        positional=0
        password_count=0
        template_application=""
        cli_application=""
        init_sql=""
        policy=required
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --parameters)
                    case "$2" in
                        password=*) password_count=$((password_count + 1)) ;;
                        applicationName=*) template_application="${2#*=}" ;;
                        tlsPolicy=*) policy="${2#*=}" ;;
                        initSql=*) init_sql="${2#*=}" ;;
                        *) echo "Unexpected parameter" >&2; exit 1 ;;
                    esac
                    shift 2
                    ;;
                --application) cli_application="$2"; shift 2 ;;
                --workspace|-e) shift 2 ;;
                -*)
                    echo "Unexpected deploy flag: $1" >&2
                    exit 1
                    ;;
                *)
                    positional=$((positional + 1))
                    # Check the actual template, not just matching CLI arguments.
                    grep -q '^param applicationName string' "$1"
                    grep -q '^  name: applicationName$' "$1"
                    shift
                    ;;
            esac
        done
        [[ "$positional" -eq 1 && "$password_count" -eq 1 ]]
        [[ -n "$cli_application" && "$template_application" == "$cli_application" ]]
        if [[ "$MOCK_RECIPE_TYPE" == "bicep" ]]; then
            [[ "$init_sql" == *"CREATE TABLE tls_init_check"* ]]
        else
            [[ -z "$init_sql" ]]
        fi
        printf '%s' "$cli_application" > "$MOCK_STATE/application"
        printf '%s' "$policy" > "$MOCK_STATE/policy"
        count=$(cat "$MOCK_STATE/deploy-count")
        count=$((count + 1))
        printf '%s' "$count" > "$MOCK_STATE/deploy-count"
        echo "deploy $policy" >> "$MOCK_STATE/calls"
        if [[ "$count" -eq "$MOCK_FAIL_DEPLOY" ]]; then
            echo "Injected deployment failure" >&2
            exit 42
        fi
        ;;
    "resource show")
        [[ "${*: -2}" == "--output json" ]]
        expected=$(cat "$MOCK_STATE/application")
        [[ "$*" == *"--application $expected"* ]]
        policy=$(cat "$MOCK_STATE/policy")
        printf '{"properties":{"host":"postgresql.test.svc.cluster.local","port":5432,"database":"appdb","tls":"%s"}}\n' "$policy"
        ;;
    "app delete")
        expected=$(cat "$MOCK_STATE/application")
        [[ "$3" == "$expected" ]]
        echo "app-cleanup" >> "$MOCK_STATE/calls"
        ;;
    *) echo "Unexpected rad command" >&2; exit 1 ;;
esac
EOF

cat > "$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$1" != --request-timeout=* ]] || shift
case "$1 $2" in
    "get pods")
        policy=$(cat "$MOCK_STATE/policy")
        printf '{"items":[{"metadata":{"name":"postgresql-pod","uid":"pod-%s"}}]}\n' "$policy"
        ;;
    "get deployments")
        policy=$(cat "$MOCK_STATE/policy")
        printf '{"items":[{"spec":{"template":{"spec":{"containers":[{"env":[{"name":"CONNECTION_POSTGRESQL_TLS","value":"%s"}]}]}}}}]}\n' "$policy"
        ;;
    "get "*) ;; # No pre-existing objects.
    "exec "*)
        if [[ "$*" == *"cat /tls/server.crt"* ]]; then
            echo "mock-public-certificate"
        elif [[ "$*" == *"stat -c"* ]]; then
            echo "600:postgres"
        elif [[ "$*" == *"SELECT count(*) FROM tls_init_check"* ]]; then
            echo 1
        elif [[ "$*" == *"PGSSLMODE=disable"* ]]; then
            if [[ "$(cat "$MOCK_STATE/policy")" == "optional" ]]; then
                echo f
            else
                echo 'FATAL: pg_hba.conf rejects connection for host "10.0.0.1", user "radadmin", database "appdb", no encryption' >&2
                exit 2
            fi
        else
            echo t
        fi
        ;;
    "delete "*)
        [[ "$*" != *"--all"* ]]
        if [[ "$2" == "deployments,services,secrets,configmaps" ]]; then
            expected=$(cat "$MOCK_STATE/application")
            [[ "$*" == *"-l radapp.io/application=$expected "* ]]
            echo "scoped-cleanup" >> "$MOCK_STATE/calls"
            [[ "$MOCK_FAIL_CLEANUP" -eq 0 ]] || exit 43
        else
            [[ "$*" == *"pod/postgresql-tls-probe secret/postgresql-tls configmap/postgresql-tls-probe-ca"* ]]
            echo "fixture-cleanup" >> "$MOCK_STATE/calls"
        fi
        ;;
    "create "*|"apply "*)
        if [[ "$*" == *"-f -"* ]]; then
            cat > /dev/null
        elif [[ "$*" == *"--dry-run=client"* ]]; then
            echo '{}'
        fi
        ;;
    "rollout "*|"wait "*) ;;
    *) echo "Unexpected kubectl command" >&2; exit 1 ;;
esac
EOF

cat > "$TEST_ROOT/bin/openssl" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "$1" == "rand" ]]; then
    echo "fake-test-password"
elif [[ "$*" == *"-noout -serial"* ]]; then
    cat > /dev/null
    echo "serial=02"
else
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -keyout|-out) : > "$2"; shift 2 ;;
            *) shift ;;
        esac
    done
fi
EOF
chmod +x "$TEST_ROOT/bin/"*

run_case() {
    local recipe="$1" fail_deploy="$2" fail_cleanup="$3" expected_status="$4"
    local state="$TEST_ROOT/$recipe-$fail_deploy-$fail_cleanup"
    mkdir -p "$state"
    printf '0' > "$state/deploy-count"
    : > "$state/calls"
    local actual_status=0
    MOCK_STATE="$state" MOCK_RECIPE_TYPE="$recipe" MOCK_FAIL_DEPLOY="$fail_deploy" \
        MOCK_FAIL_CLEANUP="$fail_cleanup" PATH="$TEST_ROOT/bin:$PATH" \
        bash "$TEST_DIR/test-tls.sh" "$recipe" test-environment test-workspace test \
        > "$state/output" 2>&1 || actual_status=$?
    if [[ "$actual_status" -ne "$expected_status" ]]; then
        cat "$state/output" >&2
        echo "Expected status $expected_status, got $actual_status ($recipe)." >&2
        return 1
    fi
    for action in app-cleanup scoped-cleanup fixture-cleanup; do
        grep -qx "$action" "$state/calls"
    done
    if [[ "$fail_deploy" -eq 0 ]]; then
        [[ "$(cat "$state/deploy-count")" -eq 8 ]]
        [[ "$(grep -c '^deploy optional$' "$state/calls")" -eq 3 ]]
        [[ "$(grep -c '^deploy required$' "$state/calls")" -eq 5 ]]
    else
        [[ "$(cat "$state/deploy-count")" -eq "$fail_deploy" ]]
    fi
}

for recipe in bicep terraform; do
    run_case "$recipe" 0 0 0
    run_case "$recipe" 3 0 42
    run_case "$recipe" 3 1 42
done
run_case bicep 0 1 1

echo "PostgreSQL TLS runner argument, application ownership, and cleanup tests passed"
