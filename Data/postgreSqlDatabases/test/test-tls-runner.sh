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
if [[ "$1" == deploy && "$2" == */upgrade-pack.bicep ]]; then
    [[ "$*" == *"packName=mock-upgrade"* && "$*" == *"recipeKind=$MOCK_RECIPE_TYPE"* ]]
    printf '%s' "${*: -1}" > "$MOCK_STATE/source"
    exit 0
fi
case "$1 $2" in
    "env update") [[ "$*" == *"--recipe-packs mock-upgrade --preview"* ]] ;;
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
        if [[ "${*: -2}" == "-o json" ]]; then
            id=stable-resource
            if [[ "${MOCK_CASE:-}" == upgrade-resource && "$(cat "$MOCK_STATE/source")" == *new ]]; then
                id=changed-resource
            fi
            printf '{"id":"%s"}\n' "$id"
            exit 0
        fi
        [[ "${*: -2}" == "--output json" ]]
        expected=$(cat "$MOCK_STATE/application")
        [[ "$*" == *"--application $expected"* ]]
        policy=$(cat "$MOCK_STATE/policy")
        [[ "${MOCK_CASE:-}" != output-policy ]] || policy=wrong
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
            if [[ "$(cat "$MOCK_STATE/deploy-count")" == 0 ]]; then
                echo '[]'
                exit 0
            fi
            if [[ "${MOCK_CASE:-}" == wrong-owner && "$3" == Radius.Data/postgreSqlDatabases ]]; then
                expected=another-application
            fi
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
        if [[ "${MOCK_CASE:-}" == repeat-uid ]]; then
            policy="$policy-$(cat "$MOCK_STATE/deploy-count")"
        fi
        printf '{"items":[{"metadata":{"name":"postgresql-pod","uid":"pod-%s"}}]}\n' "$policy"
        ;;
    "get deployments")
        policy=$(cat "$MOCK_STATE/policy")
        [[ "${MOCK_CASE:-}" != projection-policy ]] || policy=wrong
        printf '{"items":[{"spec":{"template":{"spec":{"containers":[{"env":[{"name":"CONNECTION_POSTGRESQL_TLS","value":"%s"}]}]}}}}]}\n' "$policy"
        ;;
    "get deployment")
        uid=stable-deployment
        strategy='{"type":"RollingUpdate","rollingUpdate":{"maxSurge":1,"maxUnavailable":1}}'
        if [[ "$(cat "$MOCK_STATE/source")" == *new ]]; then
            if [[ "$MOCK_RECIPE_TYPE" == bicep ]]; then
                strategy='{"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}'
            else
                strategy='{"type":"Recreate"}'
            fi
            [[ "${MOCK_CASE:-}" != upgrade-uid ]] || uid=changed-deployment
            [[ "${MOCK_CASE:-}" != upgrade-strategy ]] || strategy='{"type":"invalid"}'
        elif [[ "${MOCK_CASE:-}" == upgrade-old-strategy ]]; then
            strategy='{"type":"Recreate"}'
        fi
        printf '{"metadata":{"uid":"%s"},"spec":{"strategy":%s}}\n' "$uid" "$strategy"
        ;;
    "get secrets") echo 'test tfstate stable-state-uid' ;;
    "get "*) ;; # No pre-existing objects.
    "exec "*)
        if [[ "$*" == *"cat /tls/server.crt"* ]]; then
            echo "mock-public-certificate"
        elif [[ "$*" == *"stat -c"* ]]; then
            echo "600:postgres"
        elif [[ "$*" == *"SELECT count(*) FROM tls_init_check"* ]]; then
            echo 1
        elif [[ "$*" == *"PGSSLMODE=disable"* ]]; then
            if [[ -f "$MOCK_STATE/source" && "$(cat "$MOCK_STATE/source")" == *old ]]; then
                echo 1
            elif [[ "${MOCK_CASE:-}" == plaintext-accepted ]]; then
                echo 1
            elif [[ "${MOCK_CASE:-}" == plaintext-password ]]; then
                echo 'FATAL: password authentication failed' >&2
                exit 2
            elif [[ "$(cat "$MOCK_STATE/policy")" == "optional" ]]; then
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
            if [[ "$(cat "$MOCK_STATE/deploy-count")" == 0 ]]; then
                [[ "$*" == *"-l radapp.io/application=postgresql-tls-test-"* ||
                    "$*" == *"-l app=postgresql-tls-test-"* ]]
                echo "pre-deploy-scoped-cleanup" >> "$MOCK_STATE/calls"
                exit 0
            fi
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
args=("$@")
for index in "${!args[@]}"; do
    if [[ "${args[index]}" == -keyout ]]; then
        dirname "${args[index+1]}" > "$MOCK_STATE/certificate-dir"
    fi
done
if [[ "${MOCK_CASE:-}" == ca-failure && "$*" == *"-x509"* ]] ||
    [[ "${MOCK_CASE:-}" == signing-failure && "$1" == x509 && "$2" == -req ]]; then
    echo "mock certificate failure" >&2
    exit 55
fi
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
cat > "$TEST_ROOT/bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$TEST_ROOT/race-env" <<'EOF'
if [[ "${MOCK_CASE:-}" == readiness-race ]]; then
    # Model an already-exited observer and a stale successful kill -0 check.
    bash() {
        if [[ "$1" == */assert-readiness.sh ]]; then
            return 0
        fi
        command bash "$@"
    }
    kill() {
        printf 'kill %s\n' "$*" >> "$MOCK_STATE/calls"
        [[ "$1" == -0 ]]
    }
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

run_review_case() {
    local recipe="$1" scenario="$2" expected_error="$3"
    local state="$TEST_ROOT/review-$recipe-$scenario" actual_status=0 expected_status=1
    local readiness=0 fail_deploy=0 upgrade_pack=""
    mkdir -p "$state"
    printf '0' > "$state/deploy-count"
    # Certificate failures precede deployment; cleanup still needs synthetic ownership metadata.
    printf 'not-created' > "$state/application"
    : > "$state/calls"
    : > "$state/invocations"
    if [[ "$scenario" == readiness-race ]]; then
        readiness=1
        fail_deploy=1
        expected_status=42
    elif [[ "$scenario" == upgrade-* ]]; then
        upgrade_pack=mock-upgrade
        [[ "$scenario" != upgrade-success ]] || expected_status=0
    fi
    MOCK_STATE="$state" MOCK_RECIPE_TYPE="$recipe" MOCK_RESOURCE_GROUP=test MOCK_CASE="$scenario" \
        MOCK_FAIL_DEPLOY="$fail_deploy" MOCK_FAIL_CLEANUP=0 POSTGRESQL_TEST_READINESS="$readiness" \
        POSTGRESQL_UPGRADE_PACK="$upgrade_pack" POSTGRESQL_UPGRADE_OLD_SOURCE=old POSTGRESQL_UPGRADE_NEW_SOURCE=new \
        BASH_ENV="$TEST_ROOT/race-env" PATH="$TEST_ROOT/bin:$PATH" \
        bash "$TEST_DIR/test-tls.sh" "$recipe" \
        /planes/radius/local/resourcegroups/test/providers/Radius.Core/environments/test-environment test-workspace test \
        > "$state/output" 2>&1 || actual_status=$?
    if [[ "$actual_status" != "$expected_status" ]] || ! grep -Fq "$expected_error" "$state/output"; then
        cat "$state/output" >&2
        echo "Error: $recipe/$scenario expected exit $expected_status and diagnostic: $expected_error; got $actual_status." >&2
        return 1
    fi
    if ! grep -qx fixture-cleanup "$state/calls"; then
        echo "Error: $recipe/$scenario did not finish fixture cleanup." >&2
        return 1
    fi
    [[ ! -d "$(cat "$state/certificate-dir")" ]]
    if [[ "$scenario" == ca-failure || "$scenario" == signing-failure ]]; then
        [[ "$(grep -c '^rad resource list ' "$state/invocations")" == 5 ]]
        [[ "$(grep -c '^pre-deploy-scoped-cleanup$' "$state/calls")" == 2 ]]
    else
        grep -qx app-cleanup "$state/calls"
    fi
    if [[ "$scenario" == wrong-owner ]]; then
        if grep -q '^rad resource delete Radius.Data/postgreSqlDatabases ' "$state/invocations"; then
            echo "Error: Cleanup attempted to delete PostgreSQL owned by another application." >&2
            return 1
        fi
    elif [[ "$scenario" == readiness-race ]]; then
        [[ "$(grep -c '^kill ' "$state/calls")" == 2 ]]
        grep -q '^kill -0 ' "$state/calls"
    fi
}

for recipe in bicep terraform; do
    run_review_case "$recipe" wrong-owner 'Error: Refusing to clean up Radius.Data/postgreSqlDatabases/postgresql owned by another application.'
    run_review_case "$recipe" ca-failure 'Error: Could not generate the test CA certificate.'
    run_review_case "$recipe" signing-failure 'Error: Could not sign the test server certificate.'
    run_review_case "$recipe" repeat-uid 'Error: Unchanged repeat deployment unexpectedly recreated PostgreSQL.'
    run_review_case "$recipe" output-policy 'Error: PostgreSQL output contract or schema TLS default is incorrect.'
    run_review_case "$recipe" projection-policy "Error: CONNECTION_POSTGRESQL_TLS expected 'required', got 'wrong'."
    run_review_case "$recipe" plaintext-accepted 'Error: PostgreSQL admitted plaintext with tls=required.'
    run_review_case "$recipe" plaintext-password 'Error: Plaintext probe failed for a reason other than TLS policy: FATAL: password authentication failed'
    run_review_case "$recipe" upgrade-old-strategy 'Error: Pre-upgrade Deployment must use RollingUpdate with maxSurge and maxUnavailable.'
    run_review_case "$recipe" upgrade-uid "Error: Upgraded Deployment changed identity or has an incorrect $recipe rollout strategy."
    run_review_case "$recipe" upgrade-strategy "Error: Upgraded Deployment changed identity or has an incorrect $recipe rollout strategy."
    run_review_case "$recipe" upgrade-resource 'Error: Upgrade changed the PostgreSQL Radius resource ID.'
    run_review_case "$recipe" upgrade-success "==> In-place upgrade preserved identities and verified $recipe rollout strategy"
    for position in "${!PREFLIGHT_OBJECTS[@]}"; do
        run_preflight_case "$recipe" "$((position + 1))" empty
    done
    run_preflight_case "$recipe" 1 nonempty
    run_preflight_case "$recipe" 1 existing
    run_case "$recipe" 0 0 0
    run_case "$recipe" 3 0 42
    run_case "$recipe" 3 1 42
done
run_review_case bicep readiness-race 'Injected deployment failure'
run_case bicep 0 1 1
run_case bicep 0 2 1
run_case bicep 0 0 0 workloads

echo "PostgreSQL TLS runner argument, application ownership, and cleanup tests passed"
echo "PostgreSQL preflight tests passed: 20 lookup failures and 2 existing-object refusals"
echo "PostgreSQL review tests passed: 25 failure cases and 2 upgrade success controls"
