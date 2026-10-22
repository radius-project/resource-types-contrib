#!/bin/bash
# Remote commands expand variables inside the container.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-recipe-test.sh
source "$SCRIPT_DIR/../../../.github/scripts/lib-recipe-test.sh"

workspace="${1:-default}"
environment="${2:-default}"
recipe_kind="${3:-bicep}"
[[ "$recipe_kind" == bicep || "$recipe_kind" == terraform ]] || {
    echo "Error: expected bicep or terraform recipe kind." >&2
    exit 1
}
resolved="$(rtc_resolve_environment_path "$environment" "$workspace")"
IFS=$'\t' read -r environment_id namespace <<<"$resolved"
[[ -n "$namespace" ]] || { echo "Error: Kubernetes namespace is required." >&2; exit 1; }

# Never overwrite an operator's database or certificate.
for resource in secret/postgresql-tls secret/postgresql-credentials secret/postgresql-client-credentials \
    deployment/postgresql deployment/democontainer service/postgresql service/democontainer \
    configmap/postgresql-init-sql; do
    existing="$(kubectl get "$resource" -n "$namespace" --ignore-not-found -o name)"
    [[ -z "$existing" ]] || {
        echo "Error: $resource already exists; use an isolated test environment." >&2
        exit 1
    }
done
# Radius names are resource-group scoped, not Kubernetes-namespace scoped.
for resource in 'Radius.Data/postgreSqlDatabases postgresql' \
    'Radius.Compute/containers democontainer' 'Radius.Security/secrets postgresql-client-credentials'; do
    read -r resource_type resource_name <<<"$resource"
    resources="$(rad resource list "$resource_type" --workspace "$workspace" -o json)"
    if ! jq -e --arg name "$resource_name" \
        'type == "array" and all(.[]; .name != $name)' <<<"$resources" >/dev/null; then
        echo "Error: Cannot reserve $resource_type/$resource_name; use an isolated test resource group." >&2
        exit 1
    fi
done

app_name="postgresql-transport-$(date +%s)-$$"
app_deleted=false
tmp="$(mktemp -d)"
chmod 0700 "$tmp"
cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$app_deleted" == false ]]; then
        rad app delete "$app_name" --workspace "$workspace" --yes || status=1
    fi
    rtc_cleanup_kubernetes_resources "$namespace" "$app_name" || status=1
    kubectl delete configmap -n "$namespace" -l "radapp.io/application=$app_name" || status=1
    kubectl delete secret -n "$namespace" -l "rtc-postgresql-test=$app_name" || status=1
    rm -rf "$tmp"
    exit "$status"
}
trap cleanup EXIT

hostname="postgresql.$namespace.svc.cluster.local"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=rtc-postgresql-ca \
    -keyout "$tmp/ca.key" -out "$tmp/ca.crt" >"$tmp/openssl.log" 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=rtc-wrong-ca \
    -keyout "$tmp/wrong-ca.key" -out "$tmp/wrong-ca.crt" >>"$tmp/openssl.log" 2>&1

issue_certificate() {
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$hostname" \
        -keyout "$tmp/server.key" -out "$tmp/server.csr" >>"$tmp/openssl.log" 2>&1
    openssl x509 -req -days 1 -in "$tmp/server.csr" -CA "$tmp/ca.crt" -CAkey "$tmp/ca.key" \
        -CAcreateserial -extfile <(printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$hostname") \
        -out "$tmp/server.crt" >>"$tmp/openssl.log" 2>&1
}
install_certificate() {
    kubectl create secret tls postgresql-tls -n "$namespace" \
        --cert="$tmp/server.crt" --key="$tmp/server.key" --dry-run=client -o json |
        jq --arg app "$app_name" '.metadata.labels = {"rtc-postgresql-test": $app}' |
        kubectl apply -f -
}
issue_certificate
install_certificate

password="$(openssl rand -hex 24)"
init_sql=""
if [[ "$recipe_kind" == bicep ]]; then
    init_sql='CREATE TABLE tls_init_marker (value integer); INSERT INTO tls_init_marker VALUES (337);'
fi

deploy() {
    local policy="$1"
    app_deleted=false
    jq -n --arg password "$password" --arg app "$app_name" --arg tls "$policy" --arg init "$init_sql" \
        '{parameters: {password: {value: $password}, applicationName: {value: $app},
          tls: {value: $tls}, verifyTransport: {value: true}, initSql: {value: $init}}}' >"$tmp/parameters.json"
    timeout 360 rad deploy "$SCRIPT_DIR/app.bicep" --application "$app_name" \
        --workspace "$workspace" -e "$environment_id" --parameters "@$tmp/parameters.json"
}

wait_for_deployment() {
    local name="$1"
    kubectl rollout status deployment/"$name" -n "$namespace" --timeout=180s
    # Rollout completion can precede old Pod termination.
    for ((attempt=0; attempt<60; attempt++)); do
        if kubectl get pods -n "$namespace" -l "radapp.io/resource=$name" -o json |
            jq -e '.items | length == 1 and all(.[]; .metadata.deletionTimestamp == null)' >/dev/null; then
            return
        fi
        sleep 2
    done
    echo "Error: Old $name Pods did not terminate." >&2
    return 1
}

assert_transport() {
    local expected="$1" client fingerprint ca remote_ca plaintext_auth=reject
    wait_for_deployment postgresql
    wait_for_deployment democontainer
    client="$(kubectl get pods -n "$namespace" -l "radapp.io/application=$app_name,radapp.io/resource=democontainer" \
        -o json | jq -er '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name' | head -n1)"
    kubectl cp -n "$namespace" "$tmp/ca.crt" "$client:/tmp/postgresql-test-ca.crt"
    kubectl cp -n "$namespace" "$tmp/wrong-ca.crt" "$client:/tmp/postgresql-wrong-ca.crt"
    for ca in ca wrong-ca; do
        remote_ca=postgresql-test-ca
        if [[ "$ca" == wrong-ca ]]; then remote_ca=postgresql-wrong-ca; fi
        if [[ "$(kubectl exec -n "$namespace" "$client" -- sha256sum "/tmp/$remote_ca.crt" | cut -d' ' -f1)" != \
            "$(sha256sum "$tmp/$ca.crt" | cut -d' ' -f1)" ]]; then
            echo "Error: Client CA transfer did not preserve $ca.crt." >&2
            return 1
        fi
    done
    kubectl exec -i -n "$namespace" "$client" -- sh -s -- "$expected" <"$SCRIPT_DIR/verify-transport.sh"
    rtc_assert_postgresql_result "$app_name" "$workspace"
    rad resource show Radius.Data/postgreSqlDatabases postgresql --application "$app_name" \
        --workspace "$workspace" -o json |
        jq -e --arg expected "$expected" '.properties.tls == $expected' >/dev/null
    fingerprint="$(kubectl exec -n "$namespace" deployment/postgresql -- cat /tls-runtime/server.crt |
        openssl x509 -noout -fingerprint -sha256)"
    [[ "$fingerprint" == "$(openssl x509 -in "$tmp/server.crt" -noout -fingerprint -sha256)" ]]
    kubectl exec -n "$namespace" deployment/postgresql -- sh -ec \
        'test "$(stat -c %a /tls-runtime)" = 755; test "$(stat -c %a /tls-runtime/server.key)" = 600; test "$(stat -c %U /tls-runtime/server.key)" = postgres'
    if [[ "$expected" == optional ]]; then
        plaintext_auth=scram-sha-256
    fi
    printf 'local all all trust\nhostnossl all all 0.0.0.0/0 %s\nhostnossl all all ::/0 %s\nhostssl all all 0.0.0.0/0 scram-sha-256\nhostssl all all ::/0 scram-sha-256\n' \
        "$plaintext_auth" "$plaintext_auth" >"$tmp/expected-hba"
    kubectl exec -n "$namespace" deployment/postgresql -- cat /tls-runtime/pg_hba.conf >"$tmp/actual-hba"
    diff -u "$tmp/expected-hba" "$tmp/actual-hba"
    if [[ "$recipe_kind" == bicep ]]; then
        [[ "$(kubectl exec -n "$namespace" deployment/postgresql -- sh -ec \
            'psql -X -w -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT value FROM tls_init_marker"')" == 337 ]]
    fi
}

rad version
kubectl get nodes -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,KUBERNETES:.status.nodeInfo.kubeletVersion
for policy in "" "" optional required; do
    echo "==> PostgreSQL $recipe_kind lifecycle: ${policy:-omitted}"
    deploy "$policy"
    assert_transport "${policy:-required}"
done
kubectl get pods -n "$namespace" -l radapp.io/resource=postgresql \
    -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}'

echo "==> Restarting the container without replacing its runtime volume"
pod="$(kubectl get pods -n "$namespace" -l radapp.io/resource=postgresql -o jsonpath='{.items[0].metadata.name}')"
restarts="$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
kubectl exec -n "$namespace" "$pod" -- sh -c 'kill -TERM 1'
kubectl wait pod/"$pod" -n "$namespace" \
    --for="jsonpath={.status.containerStatuses[0].restartCount}=$((restarts + 1))" --timeout=180s
assert_transport required

echo "==> Rotating the operator certificate and explicitly restarting PostgreSQL"
old_fingerprint="$(openssl x509 -in "$tmp/server.crt" -noout -fingerprint -sha256)"
issue_certificate
[[ "$old_fingerprint" != "$(openssl x509 -in "$tmp/server.crt" -noout -fingerprint -sha256)" ]]
install_certificate
kubectl rollout restart deployment/postgresql -n "$namespace"
assert_transport required

rad app delete "$app_name" --workspace "$workspace" --yes
app_deleted=true
kubectl get secret postgresql-tls -n "$namespace" -o name
echo "PostgreSQL $recipe_kind lifecycle passed; operator Secret survived application deletion."

for failure in missing malformed; do
    echo "==> Checking $failure operator certificate fails deployment"
    kubectl delete secret postgresql-tls -n "$namespace" --ignore-not-found
    if [[ "$failure" == malformed ]]; then
        kubectl create secret generic postgresql-tls -n "$namespace" \
            --from-literal=tls.crt=invalid --from-literal=tls.key=invalid --dry-run=client -o json |
            jq --arg app "$app_name" '.metadata.labels = {"rtc-postgresql-test": $app}' |
            kubectl apply -f -
    fi
    if deploy "" >"$tmp/failed-deployment.log" 2>&1; then
        if [[ "$recipe_kind" == terraform ]]; then
            echo "Error: Terraform reported a successful deployment with $failure certificate." >&2
            exit 1
        fi
        echo "==> Bicep submitted the resources; checking the Kubernetes rollout failure"
    else
        status=$?
        if [[ "$status" == 124 ]]; then
            echo "Error: Deployment did not report certificate failure within the deadline." >&2
            exit 1
        fi
        if ! grep -q 'DeploymentFailed' "$tmp/failed-deployment.log"; then
            echo "Error: Expected a DeploymentFailed diagnostic for $failure certificate." >&2
            cat "$tmp/failed-deployment.log" >&2
            exit 1
        fi
    fi
    if kubectl rollout status deployment/postgresql -n "$namespace" --timeout=180s \
        >"$tmp/failed-rollout.log" 2>&1; then
        echo "Error: PostgreSQL became ready with $failure certificate." >&2
        exit 1
    fi
    if ! kubectl get deployment postgresql -n "$namespace" -o json | jq -e \
        '.status.observedGeneration == .metadata.generation and
         (.status.readyReplicas // 0) == 0 and (.status.availableReplicas // 0) == 0 and
         any(.status.conditions[]; .type == "Progressing" and
             .status == "False" and .reason == "ProgressDeadlineExceeded")' >/dev/null; then
        echo "Error: Expected a failed PostgreSQL rollout, not a timeout or API error." >&2
        cat "$tmp/failed-rollout.log" >&2
        exit 1
    fi
    if [[ "$failure" == missing ]]; then
        diagnostic='Create Kubernetes TLS Secret postgresql-tls'
    else
        diagnostic='could not load server certificate|could not load private key'
    fi
    for ((attempt=0; attempt<30; attempt++)); do
        if kubectl logs -n "$namespace" -l radapp.io/resource=postgresql --tail=80 \
            >"$tmp/server-error.log" 2>"$tmp/kubectl-error.log" &&
            grep -Eq "$diagnostic" "$tmp/server-error.log"; then
            break
        fi
        sleep 2
    done
    if ! grep -Eq "$diagnostic" "$tmp/server-error.log"; then
        echo "Error: Expected a PostgreSQL diagnostic for $failure certificate." >&2
        cat "$tmp/server-error.log" "$tmp/kubectl-error.log" >&2
        exit 1
    fi
    rad app delete "$app_name" --workspace "$workspace" --yes
    app_deleted=true
    rtc_cleanup_kubernetes_resources "$namespace" "$app_name"
    kubectl delete configmap -n "$namespace" -l "radapp.io/application=$app_name"
done
echo "PostgreSQL $recipe_kind certificate failure checks passed."
