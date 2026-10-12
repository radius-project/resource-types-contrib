#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/rad" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%q ' rad "$@" >> "$MOCK_STATE/invocations"
printf '\n' >> "$MOCK_STATE/invocations"
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
    "resource list"|"resource delete")
        expected=$(cat "$MOCK_STATE/application")
        case "$3" in
            Radius.Core/applications|Applications.Core/applications) name="$expected" ;;
            Radius.Compute/containers) name=democontainer ;;
            Radius.Data/postgreSqlDatabases) name=postgresql ;;
            Radius.Security/secrets) name=postgresql-client-credentials ;;
            *) echo "Unexpected cleanup type" >&2; exit 1 ;;
        esac
        if [[ "$2" == "list" ]]; then
            jq -nc --arg name "$name" --arg type "$3" \
                --arg root "/planes/radius/local/resourcegroups/$MOCK_RESOURCE_GROUP" \
                --arg application "/planes/radius/local/resourcegroups/$MOCK_RESOURCE_GROUP/providers/Radius.Core/applications/$expected" \
                '[{id: ($root + "/providers/" + $type + "/" + $name),
                    name: $name, properties: {application: $application}}]'
        else
            [[ "$4" == "$name" && "$*" == *"--yes"* ]]
            echo "typed-cleanup $3" >> "$MOCK_STATE/calls"
            if [[ "$3" == "Radius.Core/applications" ]]; then
                echo "app-cleanup" >> "$MOCK_STATE/calls"
                [[ "$MOCK_FAIL_CLEANUP" -ne 2 ]] || exit 44
            fi
        fi
        ;;
    *) echo "Unexpected rad command" >&2; exit 1 ;;
esac
EOF

cat > "$TEST_ROOT/bin/kubectl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%q ' kubectl "$@" >> "$MOCK_STATE/invocations"
printf '\n' >> "$MOCK_STATE/invocations"
if [[ "$#" -eq 7 && "$1" == get && "$2" == "${MOCK_PREFLIGHT_OBJECT:-}" &&
    "$3" == -n && "$4" == test && "$5" == --ignore-not-found && "$6" == -o && "$7" == name ]]; then
    case "${MOCK_PREFLIGHT_MODE:-}" in
        empty|nonempty)
            [[ "$MOCK_PREFLIGHT_MODE" != nonempty ]] || printf '%s\n' "$2"
            echo "Injected lookup failure for $2" >&2
            exit 77
            ;;
        existing) printf '%s\n' "$2"; exit 0 ;;
    esac
fi
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
            if [[ "$*" == *"-l radapp.io/application=$expected "* ]]; then
                echo "scoped-cleanup" >> "$MOCK_STATE/calls"
            elif [[ "$*" == *"-l app=$expected "* ]]; then
                echo "secret-label-cleanup" >> "$MOCK_STATE/calls"
            else
                echo "Cleanup selector must be application-scoped" >&2
                exit 1
            fi
            [[ "$MOCK_FAIL_CLEANUP" -ne 1 ]] || exit 43
        else
            [[ "$*" == *"pod/postgresql-tls-probe secret/postgresql-tls configmap/postgresql-tls-probe-ca"* ]]
            [[ "$*" == *"--wait=true"* && "$*" == *"--timeout=60s"* ]]
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
printf '%q ' openssl "$@" >> "$MOCK_STATE/invocations"
printf '\n' >> "$MOCK_STATE/invocations"
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
    local group="${5:-test}"
    local state="$TEST_ROOT/$recipe-$fail_deploy-$fail_cleanup-$group"
    mkdir -p "$state"
    printf '0' > "$state/deploy-count"
    : > "$state/calls"
    : > "$state/invocations"
    local actual_status=0
    MOCK_STATE="$state" MOCK_RECIPE_TYPE="$recipe" MOCK_RESOURCE_GROUP="$group" MOCK_FAIL_DEPLOY="$fail_deploy" \
        MOCK_FAIL_CLEANUP="$fail_cleanup" POSTGRESQL_TEST_READINESS=0 PATH="$TEST_ROOT/bin:$PATH" \
        bash "$TEST_DIR/test-tls.sh" "$recipe" \
        /planes/radius/local/resourcegroups/test/providers/Radius.Core/environments/test-environment test-workspace test \
        > "$state/output" 2>&1 || actual_status=$?
    if [[ "$actual_status" -ne "$expected_status" ]]; then
        cat "$state/output" >&2
        echo "Expected status $expected_status, got $actual_status ($recipe)." >&2
        return 1
    fi
    for action in app-cleanup scoped-cleanup secret-label-cleanup fixture-cleanup; do
        grep -qx "$action" "$state/calls"
    done
    for type in Radius.Compute/containers Radius.Data/postgreSqlDatabases \
        Radius.Security/secrets Radius.Core/applications Applications.Core/applications; do
        grep -qx "typed-cleanup $type" "$state/calls"
    done
    if [[ "$fail_deploy" -eq 0 ]]; then
        [[ "$(cat "$state/deploy-count")" -eq 8 ]]
        [[ "$(grep -c '^deploy optional$' "$state/calls")" -eq 3 ]]
        [[ "$(grep -c '^deploy required$' "$state/calls")" -eq 5 ]]
    else
        [[ "$(cat "$state/deploy-count")" -eq "$fail_deploy" ]]
    fi
}

PREFLIGHT_OBJECTS=(
    secret/postgresql-tls secret/postgresql-credentials deployment/postgresql
    pod/postgresql-tls-probe service/postgresql configmap/postgresql-tls-probe-ca
    secret/postgresql-client-credentials configmap/postgresql-transport configmap/postgresql-init-sql
)

run_preflight_case() {
    local recipe="$1" position="$2" mode="$3"
    local object="${PREFLIGHT_OBJECTS[position-1]}"
    local state="$TEST_ROOT/preflight-$recipe-$position-$mode"
    local actual_status=0 expected_status=77 expected_error failure=0
    mkdir -p "$state"
    printf '0' > "$state/deploy-count"
    : > "$state/calls"
    : > "$state/invocations"
    MOCK_STATE="$state" MOCK_RECIPE_TYPE="$recipe" MOCK_RESOURCE_GROUP=test MOCK_FAIL_DEPLOY=0 \
        MOCK_FAIL_CLEANUP=0 MOCK_PREFLIGHT_OBJECT="$object" MOCK_PREFLIGHT_MODE="$mode" \
        POSTGRESQL_TEST_READINESS=0 PATH="$TEST_ROOT/bin:$PATH" \
        bash "$TEST_DIR/test-tls.sh" "$recipe" \
        /planes/radius/local/resourcegroups/test/providers/Radius.Core/environments/test-environment test-workspace test \
        > "$state/output" 2>&1 || actual_status=$?
    expected_error="Error: Could not inspect $object in namespace test before PostgreSQL test setup."
    if [[ "$mode" == existing ]]; then
        expected_status=1
        expected_error="Error: $object already exists; use an isolated PostgreSQL test Environment."
    fi
    : > "$state/expected-invocations"
    for ((index=0; index<position; index++)); do
        printf '%q ' kubectl get "${PREFLIGHT_OBJECTS[index]}" -n test --ignore-not-found -o name \
            >> "$state/expected-invocations"
        printf '\n' >> "$state/expected-invocations"
    done
    if [[ "$actual_status" -ne "$expected_status" ]]; then
        echo "Error: $recipe/$position/$mode expected status $expected_status, got $actual_status." >&2
        failure=1
    fi
    if ! grep -Fxq "$expected_error" "$state/output"; then
        echo "Error: $recipe/$position/$mode missing diagnostic: $expected_error" >&2
        failure=1
    fi
    if ! cmp -s "$state/expected-invocations" "$state/invocations"; then
        echo "Error: $recipe/$position/$mode invocation trace differs from the first $position preflight gets." >&2
        diff -u "$state/expected-invocations" "$state/invocations" >&2 || true
        failure=1
    fi
    return "$failure"
}

for recipe in bicep terraform; do
    for position in "${!PREFLIGHT_OBJECTS[@]}"; do
        run_preflight_case "$recipe" "$((position + 1))" empty
    done
    run_preflight_case "$recipe" 1 nonempty
    run_preflight_case "$recipe" 1 existing
    run_case "$recipe" 0 0 0
    run_case "$recipe" 3 0 42
    run_case "$recipe" 3 1 42
done
run_case bicep 0 1 1
run_case bicep 0 2 1
run_case bicep 0 0 0 workloads

echo "PostgreSQL TLS runner argument, application ownership, and cleanup tests passed"
echo "PostgreSQL preflight tests passed: 20 lookup failures and 2 existing-object refusals"
