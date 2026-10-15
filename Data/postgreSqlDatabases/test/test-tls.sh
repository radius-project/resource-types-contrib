#!/bin/bash

# Runs through test-recipe.sh against an isolated Kubernetes test Environment.
set -euo pipefail
umask 077

RECIPE_TYPE="${1:?Recipe type is required}"
ENVIRONMENT_PATH="${2:?Environment ID is required}"
WORKSPACE_NAME="${3:?Workspace is required}"
NAMESPACE="${4:?Kubernetes namespace is required}"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="postgresql-tls-test-$(date +%s)"
CLIENT_NAME="postgresql-tls-probe"
TLS_SECRET="postgresql-tls"
HOST="postgresql.${NAMESPACE}.svc.cluster.local"
INITIAL_POLICY=disabled
if [[ -n "${POSTGRESQL_UPGRADE_PACK:-}" ]]; then
    INITIAL_POLICY="${POSTGRESQL_UPGRADE_POLICY:-default}"
fi
case "$INITIAL_POLICY" in
    default|disabled) ;;
    *) echo "Error: POSTGRESQL_UPGRADE_POLICY must be default or disabled." >&2; exit 1 ;;
esac
TLS_SECRET_FINGERPRINT=""

certificate_fingerprint() {
    kubectl get secret "$TLS_SECRET" -n "$NAMESPACE" -o json |
        jq -ce '{uid: .metadata.uid, data: .data}' | sha256sum
}

# Refuse to overwrite operator-owned resources, even in a test Environment.
for object in "secret/$TLS_SECRET" "secret/postgresql-credentials" \
    "deployment/postgresql" "pod/$CLIENT_NAME" "service/postgresql" \
    "configmap/$CLIENT_NAME-ca" "secret/postgresql-client-credentials" \
    "configmap/postgresql-transport" "configmap/postgresql-init-sql"; do
    if object_name=$(kubectl get "$object" -n "$NAMESPACE" --ignore-not-found -o name); then
        if [[ -n "$object_name" ]]; then
            echo "Error: $object already exists; use an isolated PostgreSQL test Environment." >&2
            exit 1
        fi
    else
        status=$?
        echo "Error: Could not inspect $object in namespace $NAMESPACE before PostgreSQL test setup." >&2
        exit "$status"
    fi
done

TMP_DIR="$(mktemp -d)"
READINESS_PID=""
delete_test_resource() {
    local type="$1" name="$2" metadata count
    if ! metadata=$(rad resource list "$type" --workspace "$WORKSPACE_NAME" --output json |
        jq -c --arg name "$name" '[.[] | select(.name == $name) |
            {id, name, application: .properties.application}]'); then
        echo "Error: Could not inspect $type/$name for cleanup." >&2
        return 1
    fi
    count=$(jq 'length' <<<"$metadata")
    if [[ "$count" -eq 0 ]]; then
        echo "==> Cleanup: $type/$name was not created or is already deleted"
        return 0
    fi
    if [[ "$count" -ne 1 ]]; then
        echo "Error: Cleanup found multiple resources named $type/$name." >&2
        return 1
    fi
    if [[ "$type" != "Radius.Core/applications" && "$type" != "Applications.Core/applications" ]]; then
        local resource_id application_id
        if ! resource_id=$(jq -er '.[0].id | strings | select(length > 0)' <<<"$metadata"); then
            echo "Error: Cleanup could not determine the ID of $type/$name." >&2
            return 1
        fi
        application_id="${resource_id%/providers/*}/providers/Radius.Core/applications/$APP_NAME"
        if ! jq -e --arg application "$application_id" \
            '.[0].application | strings | ascii_downcase == ($application | ascii_downcase)' \
            <<<"$metadata" >/dev/null; then
            echo "Error: Refusing to clean up $type/$name owned by another application." >&2
            return 1
        fi
    fi
    rad resource delete "$type" "$name" --workspace "$WORKSPACE_NAME" --yes
}

cleanup() {
    local status=$?
    trap - EXIT
    local cleanup_failed=0
    if [[ -n "$READINESS_PID" ]]; then
        if kill -0 "$READINESS_PID" 2>/dev/null; then
            kill "$READINESS_PID" 2>/dev/null || true
        fi
        wait "$READINESS_PID" 2>/dev/null || true
    fi
    # `rad app delete` targets the legacy application type, not Radius.Core.
    delete_test_resource Radius.Compute/containers democontainer || cleanup_failed=1
    delete_test_resource Radius.Data/postgreSqlDatabases postgresql || cleanup_failed=1
    delete_test_resource Radius.Security/secrets postgresql-client-credentials || cleanup_failed=1
    delete_test_resource Radius.Core/applications "$APP_NAME" || cleanup_failed=1
    delete_test_resource Applications.Core/applications "$APP_NAME" || cleanup_failed=1
    if [[ -n "$TLS_SECRET_FINGERPRINT" && "$(certificate_fingerprint)" != "$TLS_SECRET_FINGERPRINT" ]]; then
        echo "Error: Application cleanup changed the external TLS Secret." >&2
        cleanup_failed=1
    fi
    # Remove only this test application's leftovers if Recipe cleanup is incomplete.
    kubectl delete deployments,services,secrets,configmaps -n "$NAMESPACE" \
        -l "radapp.io/application=$APP_NAME" --ignore-not-found --timeout=60s || cleanup_failed=1
    kubectl delete deployments,services,secrets,configmaps -n "$NAMESPACE" \
        -l "app=$APP_NAME" --ignore-not-found --timeout=60s || cleanup_failed=1
    kubectl delete "pod/$CLIENT_NAME" "secret/$TLS_SECRET" "configmap/$CLIENT_NAME-ca" -n "$NAMESPACE" \
        --ignore-not-found --wait=true --timeout=60s || cleanup_failed=1
    rm -f "$TMP_DIR/ca.key" "$TMP_DIR/ca.crt" "$TMP_DIR/server.key" \
        "$TMP_DIR/server.csr" "$TMP_DIR/server.crt" "$TMP_DIR/extensions" "$TMP_DIR/baseline.sql"
    rmdir "$TMP_DIR"
    if [[ "$status" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$TMP_DIR/ca.key" -out "$TMP_DIR/ca.crt" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
    -subj "/CN=Radius PostgreSQL test CA" >/dev/null 2>&1 || {
        echo "Error: Could not generate the test CA certificate." >&2
        exit 1
    }
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n' "$HOST" > "$TMP_DIR/extensions"

publish_certificate() {
    local serial="$1"
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$TMP_DIR/server.key" -out "$TMP_DIR/server.csr" \
        -subj "/CN=Radius PostgreSQL test server" >/dev/null 2>&1 || {
            echo "Error: Could not generate the test server certificate request." >&2
            return 1
        }
    openssl x509 -req -in "$TMP_DIR/server.csr" -CA "$TMP_DIR/ca.crt" \
        -CAkey "$TMP_DIR/ca.key" -set_serial "$serial" -days 2 \
        -extfile "$TMP_DIR/extensions" -out "$TMP_DIR/server.crt" >/dev/null 2>&1 || {
            echo "Error: Could not sign the test server certificate." >&2
            return 1
        }
    # Server-side apply avoids copying private keys into last-applied annotations.
    kubectl create secret tls "$TLS_SECRET" -n "$NAMESPACE" \
        --cert="$TMP_DIR/server.crt" --key="$TMP_DIR/server.key" \
        --dry-run=client -o json | kubectl apply --server-side --field-manager=postgresql-tls-test -f - >/dev/null
}

if [[ "$INITIAL_POLICY" != disabled ]]; then
    publish_certificate 1
    TLS_SECRET_FINGERPRINT=$(certificate_fingerprint)
fi
PASSWORD="$(openssl rand -hex 24)"
LAST_POLICY=""

server_pod_uid() {
    kubectl get pods -n "$NAMESPACE" -l radapp.io/resource=postgresql -o json |
        jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.uid'
}

deploy_policy() {
    local policy="$1"
    local previous_uid=""
    if [[ "$LAST_POLICY" == "$policy" ]]; then
        previous_uid=$(server_pod_uid)
    fi
    local parameters=(--parameters "password=$PASSWORD" --parameters "applicationName=$APP_NAME")
    if [[ "$policy" != "default" ]]; then
        parameters+=(--parameters "tlsPolicy=$policy")
    fi
    if [[ "$RECIPE_TYPE" == "bicep" ]]; then
        local init_sql="CREATE TABLE tls_init_check (id integer); INSERT INTO tls_init_check VALUES (1);"
        if [[ -z "$LAST_POLICY" && "${POSTGRESQL_TEST_READINESS:-1}" == 1 ]]; then
            init_sql="SELECT pg_sleep(30); $init_sql"
        fi
        parameters+=(--parameters "initSql=$init_sql")
    fi
    echo "==> Deploying PostgreSQL ($RECIPE_TYPE, tls=$policy)"
    rad deploy "$TEST_DIR/app.bicep" --application "$APP_NAME" \
        --workspace "$WORKSPACE_NAME" -e "$ENVIRONMENT_PATH" "${parameters[@]}"
    kubectl rollout status deployment/postgresql -n "$NAMESPACE" --timeout=180s
    if [[ -n "$previous_uid" && "$(server_pod_uid)" != "$previous_uid" ]]; then
        echo "Error: Unchanged repeat deployment unexpectedly recreated PostgreSQL." >&2
        return 1
    fi
    LAST_POLICY="$policy"
}

if [[ -n "${POSTGRESQL_UPGRADE_PACK:-}" ]]; then
    switch_upgrade_source() {
        rad deploy "$TEST_DIR/upgrade-pack.bicep" --workspace "$WORKSPACE_NAME" -e "$ENVIRONMENT_PATH" \
            --parameters "packName=$POSTGRESQL_UPGRADE_PACK" \
            --parameters "recipeKind=$RECIPE_TYPE" --parameters "postgresqlSource=$1"
        rad env update "${ENVIRONMENT_PATH##*/}" --workspace "$WORKSPACE_NAME" \
            --recipe-packs "$POSTGRESQL_UPGRADE_PACK" --preview
    }
    switch_upgrade_source "${POSTGRESQL_UPGRADE_OLD_SOURCE:?Old source required}"
    # Old recipes ignore tls; establish a real running Deployment before upgrading.
    LAST_POLICY=baseline
    deploy_policy default
    old_json=$(kubectl get deployment postgresql -n "$NAMESPACE" -o json)
    jq -e '.spec.strategy.type == "RollingUpdate" and
        (.spec.strategy.rollingUpdate | has("maxSurge") and has("maxUnavailable"))' \
        <<<"$old_json" >/dev/null || {
            echo "Error: Pre-upgrade Deployment must use RollingUpdate with maxSurge and maxUnavailable." >&2
            exit 1
        }
    OLD_DEPLOYMENT_UID=$(jq -r '.metadata.uid' <<<"$old_json")
    OLD_RESOURCE_ID=$(rad resource show Radius.Data/postgreSqlDatabases postgresql \
        --workspace "$WORKSPACE_NAME" -o json | jq -er '.id')
    baseline_ready=false
    for ((attempt=0; attempt<24; attempt++)); do
        # Expand credentials inside the server container, never in local CLI arguments.
        # shellcheck disable=SC2016
        if kubectl --request-timeout=15s exec -n "$NAMESPACE" deployment/postgresql -c postgres -- \
            /bin/sh -ec 'PGSSLMODE=disable PGPASSWORD="$POSTGRES_PASSWORD" psql -X -w -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT 1"' \
            >/dev/null 2>&1; then
            baseline_ready=true
            break
        fi
        sleep 5
    done
    [[ "$baseline_ready" == true ]] || {
        echo "Error: Pre-upgrade database did not answer a plaintext TCP query." >&2
        exit 1
    }
    # shellcheck disable=SC2016
    kubectl --request-timeout=15s exec -n "$NAMESPACE" deployment/postgresql -c postgres -- \
        /bin/sh -ec 'PGSSLMODE=disable PGPASSWORD="$POSTGRES_PASSWORD" psql -X -w -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "CREATE TABLE radius_upgrade_marker (id integer); INSERT INTO radius_upgrade_marker VALUES (73)"' >/dev/null || {
        echo "Error: Could not create the pre-upgrade backup marker." >&2; exit 1;
    }
    # shellcheck disable=SC2016
    kubectl --request-timeout=15s exec -n "$NAMESPACE" deployment/postgresql -c postgres -- \
        /bin/sh -ec 'PGSSLMODE=disable PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -w -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --table=radius_upgrade_marker' >"$TMP_DIR/baseline.sql" || {
        echo "Error: Could not back up the pre-upgrade marker." >&2; exit 1;
    }
    [[ -s "$TMP_DIR/baseline.sql" ]] || { echo "Error: Pre-upgrade backup was empty." >&2; exit 1; }
    OLD_POD_UID=$(server_pod_uid)
    if [[ "$RECIPE_TYPE" == terraform ]]; then
        OLD_STATE_IDS=$(kubectl get secrets -A -l tfstate=true \
            -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,UID:.metadata.uid' \
            --no-headers | sort)
        [[ -n "$OLD_STATE_IDS" ]] || {
            echo "Error: No Terraform backend state Secret metadata found." >&2
            exit 1
        }
    fi
    echo "==> Pre-upgrade RollingUpdate database ready: resource=$OLD_RESOURCE_ID deployment=$OLD_DEPLOYMENT_UID"
    switch_upgrade_source "${POSTGRESQL_UPGRADE_NEW_SOURCE:?New source required}"
    LAST_POLICY=""
fi

if [[ "$RECIPE_TYPE" == bicep && "${POSTGRESQL_TEST_READINESS:-1}" == 1 ]]; then
    bash "$TEST_DIR/assert-readiness.sh" "$NAMESPACE" postgresql "${OLD_POD_UID:-}" &
    READINESS_PID=$!
fi
deploy_policy "$INITIAL_POLICY"
if [[ -n "$READINESS_PID" ]]; then
    if ! wait "$READINESS_PID"; then
        READINESS_PID=""
        echo "Error: PostgreSQL initialization readiness test failed." >&2
        exit 1
    fi
    READINESS_PID=""
fi
if [[ -n "${POSTGRESQL_UPGRADE_PACK:-}" ]]; then
    new_json=$(kubectl get deployment postgresql -n "$NAMESPACE" -o json)
    jq -e --arg uid "$OLD_DEPLOYMENT_UID" --arg kind "$RECIPE_TYPE" '.metadata.uid == $uid and
        (if $kind == "bicep" then
            .spec.strategy.type == "RollingUpdate" and
            .spec.strategy.rollingUpdate.maxSurge == 0 and
            .spec.strategy.rollingUpdate.maxUnavailable == 1
         else .spec.strategy.type == "Recreate" and (.spec.strategy | has("rollingUpdate") | not)
         end)' \
        <<<"$new_json" >/dev/null || {
            echo "Error: Upgraded Deployment changed identity or has an incorrect $RECIPE_TYPE rollout strategy." >&2
            exit 1
        }
    new_resource_id=$(rad resource show Radius.Data/postgreSqlDatabases postgresql \
        --workspace "$WORKSPACE_NAME" -o json | jq -er '.id')
    [[ "$new_resource_id" == "$OLD_RESOURCE_ID" ]] || {
        echo "Error: Upgrade changed the PostgreSQL Radius resource ID." >&2
        exit 1
    }
    if [[ "$RECIPE_TYPE" == terraform ]]; then
        new_state_ids=$(kubectl get secrets -A -l tfstate=true \
            -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,UID:.metadata.uid' \
            --no-headers | sort)
        [[ "$new_state_ids" == "$OLD_STATE_IDS" ]] || {
            echo "Error: Terraform upgrade changed backend state Secret identities." >&2
            exit 1
        }
    fi
    echo "==> In-place upgrade preserved identities and verified $RECIPE_TYPE rollout strategy"
    restore_mode=require
    [[ "$INITIAL_POLICY" != disabled ]] || restore_mode=disable
    # shellcheck disable=SC2016
    kubectl --request-timeout=15s exec -i -n "$NAMESPACE" deployment/postgresql -c postgres -- \
        env "PGSSLMODE=$restore_mode" /bin/sh -ec 'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -w -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' \
        <"$TMP_DIR/baseline.sql" >/dev/null || {
        echo "Error: Could not restore the pre-upgrade backup." >&2; exit 1;
    }
    # shellcheck disable=SC2016
    restored=$(kubectl --request-timeout=15s exec -n "$NAMESPACE" deployment/postgresql -c postgres -- \
        env "PGSSLMODE=$restore_mode" /bin/sh -ec 'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -w -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT id FROM radius_upgrade_marker"')
    [[ "$restored" == 73 ]] || { echo "Error: Restored upgrade marker did not match." >&2; exit 1; }
fi

# The CA is public; only the server Secret and the private temp directory hold keys.
kubectl create configmap "$CLIENT_NAME-ca" -n "$NAMESPACE" \
    --from-file=ca.crt="$TMP_DIR/ca.crt" >/dev/null
cat <<EOF | kubectl create -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $CLIENT_NAME
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
    - name: psql
      image: postgres:16-alpine
      command: ["sleep", "7200"]
      env:
        - name: PGUSER
          valueFrom:
            secretKeyRef: {name: postgresql-credentials, key: USERNAME}
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef: {name: postgresql-credentials, key: PASSWORD}
        - {name: PGHOST, value: "$HOST"}
        - {name: PGPORT, value: "5432"}
        - {name: PGDATABASE, value: appdb}
        - {name: PGCONNECT_TIMEOUT, value: "5"}
        - {name: PGOPTIONS, value: "-c statement_timeout=5000"}
        - {name: PGSSLROOTCERT, value: /ca/ca.crt}
      volumeMounts:
        - {name: ca, mountPath: /ca, readOnly: true}
  volumes:
    - name: ca
      configMap: {name: "$CLIENT_NAME-ca"}
EOF
kubectl wait pod/"$CLIENT_NAME" -n "$NAMESPACE" --for=condition=Ready --timeout=120s

query() {
    kubectl --request-timeout=15s exec -n "$NAMESPACE" "$CLIENT_NAME" -- \
        env "PGSSLMODE=$1" psql -X -A -t -w -v ON_ERROR_STOP=1 -c "$2"
}

assert_query() {
    local mode="$1" sql="$2" expected="$3" actual="" attempt
    for ((attempt=1; attempt<=24; attempt++)); do
        if actual=$(query "$mode" "$sql" 2>&1) && [[ "$actual" == "$expected" ]]; then
            return 0
        fi
        sleep 5
    done
    echo "Error: $mode probe did not return '$expected': $actual" >&2
    return 1
}

assert_projection() {
    local expected="$1" actual="" attempt
    for ((attempt=1; attempt<=24; attempt++)); do
        actual=$(kubectl get deployments -n "$NAMESPACE" \
            -l radapp.io/resource=democontainer -o json | jq -r '
                .items[].spec.template.spec.containers[].env[]? |
                select(.name == "CONNECTION_POSTGRESQL_TLS") | .value')
        if [[ "$actual" == "$expected" ]]; then
            return 0
        fi
        sleep 5
    done
    echo "Error: CONNECTION_POSTGRESQL_TLS expected '$expected', got '$actual'." >&2
    return 1
}

assert_policy() {
    local policy="$1" expected="$1" resource_json error
    [[ "$expected" != "default" ]] || expected=required
    resource_json=$(rad resource show Radius.Data/postgreSqlDatabases postgresql \
        --application "$APP_NAME" --workspace "$WORKSPACE_NAME" --output json)
    jq -e --arg tls "$expected" --arg host "$HOST" '
        .properties.host == $host and .properties.port == 5432 and
        .properties.database == "appdb" and .properties.tls == $tls and
        (.properties | has("secrets") | not)
    ' <<<"$resource_json" >/dev/null || {
        echo "Error: PostgreSQL output contract or schema TLS default is incorrect." >&2
        return 1
    }
    assert_projection "$expected"
    local workload
    workload=$(kubectl get deployment postgresql -n "$NAMESPACE" -o json)
    if [[ "$expected" == disabled ]]; then
        jq -e '
          .spec.template as $t |
          ($t.spec.initContainers // [] | length == 0) and
          ($t.spec.volumes | all(.name != "tls" and .name != "tls-source")) and
          ($t.spec.containers[0].volumeMounts | all(.name != "tls")) and
          ($t.metadata.annotations | has("radapp.io/postgresql-tls-revision") | not) and
          ($t.spec.containers[0].args | index("ssl=off") != null) and
          ($t.spec.containers[0].args | all(contains("ssl_cert_file") or contains("ssl_key_file") or contains("ssl_min_protocol_version") | not))
        ' <<<"$workload" >/dev/null || {
            echo "Error: Disabled workload retained certificate configuration or failed to disable TLS." >&2
            return 1
        }
        assert_query disable 'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()' f
        if error=$(query require 'SELECT 1' 2>&1); then
            echo "Error: Disabled PostgreSQL admitted a TLS-forcing client." >&2
            return 1
        fi
        grep -Eq 'server does not support SSL|SSL is not enabled on the server' <<<"$error" || {
            echo "Error: Disabled TLS probe failed for an unrelated reason: $error" >&2
            return 1
        }
        if error=$(kubectl --request-timeout=15s exec -n "$NAMESPACE" "$CLIENT_NAME" -- \
            env PGSSLMODE=disable PGPASSWORD=deliberately-wrong-password \
            psql -X -A -t -w -v ON_ERROR_STOP=1 -c 'SELECT 1' 2>&1); then
            echo "Error: Disabled PostgreSQL admitted the wrong password." >&2
            return 1
        fi
        grep -Fq 'password authentication failed' <<<"$error" || {
            echo "Error: Wrong-password probe failed for an unrelated reason: $error" >&2
            return 1
        }
        if [[ "$RECIPE_TYPE" == bicep ]]; then
            assert_query disable 'SELECT count(*) FROM tls_init_check' 1
        fi
        echo "==> PostgreSQL tls=$policy TCP and output probes passed"
        return
    fi
    jq -e '.spec.template as $t |
      ($t.spec.initContainers | any(.name == "prepare-tls")) and
      ($t.spec.volumes | any(.name == "tls-source")) and
      ($t.spec.volumes | any(.name == "tls")) and
      ($t.spec.containers[0].volumeMounts | any(.name == "tls")) and
      ($t.metadata.annotations | has("radapp.io/postgresql-tls-revision"))' \
      <<<"$workload" >/dev/null || {
        echo "Error: Enabled workload is missing TLS configuration." >&2
        return 1
    }
    assert_query require 'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()' t
    assert_query verify-full 'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()' t
    if [[ "$expected" == "optional" ]]; then
        assert_query disable 'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()' f
    else
        if error=$(query disable 'SELECT 1' 2>&1); then
            echo "Error: PostgreSQL admitted plaintext with tls=$expected." >&2
            return 1
        fi
        # Same endpoint/credentials just passed TLS probes. Reject DNS, password,
        # startup and other failures masquerading as policy enforcement.
        if ! grep -Eq 'pg_hba.conf rejects connection .*no encryption' <<<"$error"; then
            echo "Error: Plaintext probe failed for a reason other than TLS policy: $error" >&2
            return 1
        fi
    fi
    if [[ "$RECIPE_TYPE" == "bicep" ]]; then
        assert_query verify-full 'SELECT count(*) FROM tls_init_check' 1
    fi
    echo "==> PostgreSQL tls=$policy TCP and output probes passed"
}

assert_policy "$INITIAL_POLICY"
if [[ "$INITIAL_POLICY" == disabled ]]; then
    [[ -z "$(kubectl get secret "$TLS_SECRET" -n "$NAMESPACE" --ignore-not-found -o name)" ]] || {
        echo "Error: Fresh disabled deployment unexpectedly needs a TLS Secret." >&2
        exit 1
    }
    deploy_policy disabled
    assert_policy disabled
    publish_certificate 1
    TLS_SECRET_FINGERPRINT=$(certificate_fingerprint)
fi
# Repeat deployments and both transitions exercise pod-template policy selection.
# Rollouts use fresh ephemeral databases; this does not test retained PGDATA.
for policy in required required disabled optional optional disabled required optional default; do
    deploy_policy "$policy"
    assert_policy "$policy"
    [[ "$(certificate_fingerprint)" == "$TLS_SECRET_FINGERPRINT" ]] || {
        echo "Error: Policy transition changed the external TLS Secret." >&2
        exit 1
    }
done

# Rotation is explicit: the recipe copies the Secret at pod startup, never at
# first database initialization. In production use the recipe revision parameter
# or an operator-triggered rollout after protecting data.
publish_certificate 2
TLS_SECRET_FINGERPRINT=$(certificate_fingerprint)
kubectl rollout restart deployment/postgresql -n "$NAMESPACE"
kubectl rollout status deployment/postgresql -n "$NAMESPACE" --timeout=180s
assert_policy default
SERVER_POD=$(kubectl get pods -n "$NAMESPACE" -l radapp.io/resource=postgresql \
    -o json | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name')
SERIAL=$(kubectl exec -n "$NAMESPACE" "$SERVER_POD" -c postgres -- cat /tls/server.crt |
    openssl x509 -noout -serial)
[[ "$SERIAL" == "serial=02" ]] || {
    echo "Error: PostgreSQL did not load the rotated certificate." >&2
    exit 1
}
KEY_MODE=$(kubectl exec -n "$NAMESPACE" "$SERVER_POD" -c postgres -- \
    stat -c '%a:%U' /tls/server.key)
[[ "$KEY_MODE" == "600:postgres" ]] || {
    echo "Error: PostgreSQL TLS key permissions must be 600 and owned by postgres." >&2
    exit 1
}

echo "==> PostgreSQL TLS deployment suite passed"
