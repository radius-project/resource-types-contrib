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

# Refuse to overwrite operator-owned resources, even in a test Environment.
for object in "secret/$TLS_SECRET" "secret/postgresql-credentials" \
    "deployment/postgresql" "pod/$CLIENT_NAME" "service/postgresql" \
    "configmap/$CLIENT_NAME-ca" "secret/postgresql-client-credentials" \
    "configmap/postgresql-transport" "configmap/postgresql-init-sql"; do
    if [[ -n "$(kubectl get "$object" -n "$NAMESPACE" --ignore-not-found -o name)" ]]; then
        echo "Error: $object already exists; use an isolated PostgreSQL test Environment." >&2
        exit 1
    fi
done

TMP_DIR="$(mktemp -d)"
cleanup() {
    local status=$?
    trap - EXIT
    local cleanup_failed=0
    rad app delete "$APP_NAME" --workspace "$WORKSPACE_NAME" --yes || cleanup_failed=1
    # Remove only this test application's leftovers if Recipe cleanup is incomplete.
    kubectl delete deployments,services,secrets,configmaps -n "$NAMESPACE" \
        -l "radapp.io/application=$APP_NAME" --ignore-not-found --timeout=60s || cleanup_failed=1
    kubectl delete "pod/$CLIENT_NAME" "secret/$TLS_SECRET" "configmap/$CLIENT_NAME-ca" -n "$NAMESPACE" \
        --ignore-not-found --wait=false || cleanup_failed=1
    rm -f "$TMP_DIR/ca.key" "$TMP_DIR/ca.crt" "$TMP_DIR/server.key" \
        "$TMP_DIR/server.csr" "$TMP_DIR/server.crt" "$TMP_DIR/extensions"
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
    -subj "/CN=Radius PostgreSQL test CA" >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n' "$HOST" > "$TMP_DIR/extensions"

publish_certificate() {
    local serial="$1"
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$TMP_DIR/server.key" -out "$TMP_DIR/server.csr" \
        -subj "/CN=$HOST" >/dev/null 2>&1
    openssl x509 -req -in "$TMP_DIR/server.csr" -CA "$TMP_DIR/ca.crt" \
        -CAkey "$TMP_DIR/ca.key" -set_serial "$serial" -days 2 \
        -extfile "$TMP_DIR/extensions" -out "$TMP_DIR/server.crt" >/dev/null 2>&1
    # Server-side apply avoids copying private keys into last-applied annotations.
    kubectl create secret tls "$TLS_SECRET" -n "$NAMESPACE" \
        --cert="$TMP_DIR/server.crt" --key="$TMP_DIR/server.key" \
        --dry-run=client -o json | kubectl apply --server-side --field-manager=postgresql-tls-test -f - >/dev/null
}

publish_certificate 1
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
        parameters+=(--parameters "initSql=CREATE TABLE tls_init_check (id integer); INSERT INTO tls_init_check VALUES (1);")
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

deploy_policy default

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

assert_policy default
# Repeat deployment and both policy transitions must apply without initdb hooks.
for policy in required required optional optional required optional default; do
    deploy_policy "$policy"
    assert_policy "$policy"
done

# Rotation is explicit: the recipe copies the Secret at pod startup, never at
# first database initialization. In production use the recipe revision parameter
# or an operator-triggered rollout after protecting data.
publish_certificate 2
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
