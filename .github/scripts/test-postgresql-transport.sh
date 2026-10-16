#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-recipe-test.sh"
test_file="$1" environment="$2" workspace="$3" namespace="$4" recipe_type="$5"
app_name="postgresql-tls-$(date +%s)"
test_root="$(mktemp -d)"
app_started=false
secret_created=false
cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$app_started" == true ]]; then
        rad app delete "$app_name" --workspace "$workspace" --yes || status=1
        rtc_cleanup_kubernetes_resources "$namespace" "$app_name" || status=1
        kubectl delete configmap -n "$namespace" -l "radapp.io/application=$app_name" || status=1
    fi
    if [[ "$secret_created" == true ]]; then
        kubectl delete secret postgresql-tls -n "$namespace" || status=1
    fi
    rm -rf "$test_root"
    exit "$status"
}
trap cleanup EXIT
umask 077
[[ -n "$namespace" ]] || { echo "Error: An isolated Kubernetes namespace is required." >&2; exit 1; }
password="$(openssl rand -hex 24)"
init_sql=''
[[ "$recipe_type" != bicep ]] || init_sql='CREATE TABLE tls_init_test (value integer); INSERT INTO tls_init_test VALUES (337);'
jq -n --arg name "$app_name" --arg password "$password" --arg sql "$init_sql" \
    '{parameters:{applicationName:{value:$name},password:{value:$password},verifyTransport:{value:"true"},initSql:{value:$sql}}}' \
    > "$test_root/parameters.json"
unset password

deploy() {
    app_started=true
    timeout 300 rad deploy "$test_file" --application "$app_name" --workspace "$workspace" \
        -e "$environment" --parameters "@$test_root/parameters.json" --parameters "tls=$1"
}

resource_json() {
    rad resource show Radius.Data/postgreSqlDatabases postgresql \
        --application "$app_name" --workspace "$workspace" -o json
}

rollout() {
    kubectl rollout status deployment/postgresql -n "$namespace" --timeout=180s
    kubectl get deployment postgresql -n "$namespace" -o json | jq -e '
        .status.observedGeneration >= .metadata.generation and
        .status.updatedReplicas == .spec.replicas and
        .status.readyReplicas == .spec.replicas and
        .status.replicas == .spec.replicas' >/dev/null
}

probe() {
    local policy="$1" client
    rollout
    resource_json | jq -e --arg policy "$policy" '.properties.tls == $policy' >/dev/null
    client=$(kubectl get deployment -n "$namespace" \
        -l "radapp.io/application=$app_name,radapp.io/resource=postgresclient" -o json |
        jq -er '.items | if length == 1 then .[0].metadata.name else error("Expected one probe client") end')
    kubectl rollout status "deployment/$client" -n "$namespace" --timeout=180s
    local -a trust=()
    if [[ "$policy" != disabled ]]; then
        kubectl exec -i -n "$namespace" "deployment/$client" -- sh -c 'cat > /tmp/pg-ca.crt' < "$test_root/ca.crt"
        kubectl exec -i -n "$namespace" "deployment/$client" -- sh -c 'cat > /tmp/pg-untrusted-ca.crt' < "$test_root/untrusted.crt"
        trust=(env PGSSLROOTCERT=/tmp/pg-ca.crt PGSSLUNTRUSTEDROOTCERT=/tmp/pg-untrusted-ca.crt)
        local actual expected
        actual=$(kubectl exec -n "$namespace" deployment/postgresql -- cat /postgres-config/server.crt | openssl x509 -noout -serial)
        expected=$(openssl x509 -in "$test_root/tls.crt" -noout -serial)
        [[ "$actual" == "$expected" ]] || { echo "Error: Server copied the wrong certificate." >&2; return 1; }
        [[ "$(kubectl exec -n "$namespace" deployment/postgresql -- stat -c '%a:%U' /postgres-config/server.key)" == '600:postgres' ]]
    else
        kubectl get deployment postgresql -n "$namespace" -o json |
            jq -e '[.spec.template.spec.volumes[] | select(has("secret"))] | length == 0' >/dev/null
    fi
    kubectl exec -i -n "$namespace" "deployment/$client" -- "${trust[@]}" sh -s -- "$policy" \
        < "$(dirname "$test_file")/verify-transport.sh"
    rtc_assert_postgresql_result "$app_name" "$workspace"
    if [[ "$recipe_type" == bicep ]]; then
        local value attempt
        for attempt in {1..10}; do
          if value=$(kubectl exec -n "$namespace" "deployment/$client" -- sh -ec '
            export PGPASSWORD="$CONNECTION_POSTGRESQL_PASSWORD" PGCONNECT_TIMEOUT=5
            mode=require; [ "$CONNECTION_POSTGRESQL_TLS" != disabled ] || mode=disable
            timeout 10 psql -X -w -At -v ON_ERROR_STOP=1 \
              "host=$CONNECTION_POSTGRESQL_HOST port=$CONNECTION_POSTGRESQL_PORT dbname=$CONNECTION_POSTGRESQL_DATABASE user=$CONNECTION_POSTGRESQL_USERNAME sslmode=$mode" \
              -c "SELECT value FROM tls_init_test"
          '); then
            break
          fi
          [[ "$attempt" != 10 ]] || { echo "Error: Initialization query retries exhausted." >&2; return 1; }
          sleep 2
        done
        [[ "$value" == 337 ]] || { echo "Error: Bicep initSql was not preserved." >&2; return 1; }
    fi
}

# First deploy without a certificate and discover the actual recipe namespace.
deploy disabled
host=$(resource_json | jq -er '.properties.host')
namespace="${host#postgresql.}"
namespace="${namespace%.svc.cluster.local}"
[[ "$host" == "postgresql.$namespace.svc.cluster.local" && "$namespace" != "$host" ]] ||
    { echo "Error: Unexpected PostgreSQL Service hostname." >&2; exit 1; }
kubectl get service postgresql -n "$namespace" -o json |
    jq -e --arg app "$app_name" '.metadata.labels["radapp.io/application"] == $app' >/dev/null
probe disabled
if kubectl get secret postgresql-tls -n "$namespace" >/dev/null 2>&1; then
    echo "Error: Refusing to overwrite an operator TLS Secret; use an isolated environment." >&2
    exit 1
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=PostgreSQL test CA' \
    -keyout "$test_root/ca.key" -out "$test_root/ca.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Untrusted test CA' \
    -keyout "$test_root/untrusted.key" -out "$test_root/untrusted.crt" >/dev/null 2>&1
issue_certificate() {
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$host" \
        -keyout "$test_root/tls.key" -out "$test_root/tls.csr" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$host" > "$test_root/extensions"
    openssl x509 -req -in "$test_root/tls.csr" -CA "$test_root/ca.crt" \
        -CAkey "$test_root/ca.key" -CAcreateserial -days 1 \
        -extfile "$test_root/extensions" -out "$test_root/tls.crt" >/dev/null 2>&1
}
issue_certificate
kubectl create secret tls postgresql-tls -n "$namespace" \
    --cert="$test_root/tls.crt" --key="$test_root/tls.key" >/dev/null
secret_created=true
secret_uid=$(kubectl get secret postgresql-tls -n "$namespace" -o jsonpath='{.metadata.uid}')

declare -A restarted=()
for policy in omitted optional disabled required disabled optional required required; do
    echo "==> PostgreSQL $recipe_type policy: $policy"
    deploy "$policy"
    expected="$policy"
    [[ "$policy" != omitted ]] || expected=required
    probe "$expected"
    if [[ -z "${restarted[$expected]:-}" ]]; then
        kubectl rollout restart deployment/postgresql -n "$namespace"
        probe "$expected"
        restarted[$expected]=true
    fi
done

issue_certificate
kubectl create secret tls postgresql-tls -n "$namespace" \
    --cert="$test_root/tls.crt" --key="$test_root/tls.key" --dry-run=client -o json |
    kubectl apply -f - >/dev/null
[[ "$(kubectl get secret postgresql-tls -n "$namespace" -o jsonpath='{.metadata.uid}')" == "$secret_uid" ]]
kubectl rollout restart deployment/postgresql -n "$namespace"
probe required

# Unlike pod replacement, this retains the memory-backed configuration volume.
pod=$(kubectl get pod -n "$namespace" -l "radapp.io/application=$app_name,radapp.io/resource=postgresql" \
    -o json | jq -er '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name')
restart_count=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.containerStatuses[0].restartCount}')
# PostgreSQL's fast shutdown (the image's stop signal) closes idle clients too.
kubectl exec "$pod" -n "$namespace" -- sh -c 'kill -INT 1'
for attempt in {1..60}; do
    if kubectl get pod "$pod" -n "$namespace" -o json |
        jq -e --argjson before "$restart_count" '.status.containerStatuses[0] | .restartCount > $before and .ready' >/dev/null; then
        break
    fi
    if [[ "$attempt" == 60 ]]; then
        echo "Error: PostgreSQL container did not restart." >&2
        kubectl logs "$pod" -n "$namespace" --tail=40 >&2
        exit 1
    fi
    sleep 2
done
probe required
echo "==> PostgreSQL transport, transitions, repeat deployment, initialization and rotation passed"
