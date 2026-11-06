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
# Allow the normal 600-second Kubernetes/provider waits plus observation overhead.
rollout_timeout=660
deploy_timeout=780
certificate_timeout=180
deployment_pid=""
deployment_pending=false
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
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
app_deleted=false
tmp="$(mktemp -d)"
chmod 0700 "$tmp"
cleanup() {
    local status=$? diagnostics_collected=false
    trap - EXIT
    if [[ "$status" -ne 0 ]]; then
        rtc_collect_test_diagnostics Radius.Data/postgreSqlDatabases "$app_name" "$started" ||
            echo "Error: PostgreSQL diagnostic collection failed; continuing cleanup." >&2
        diagnostics_collected=true
    fi
    if [[ "$deployment_pending" == true ]]; then
        if ! settle_deployment; then
            if [[ "$diagnostics_collected" == false ]]; then
                rtc_collect_test_diagnostics Radius.Data/postgreSqlDatabases "$app_name" "$started" ||
                    echo "Error: PostgreSQL diagnostic collection failed after unsettled deployment." >&2
            fi
            echo "Error: Deployment has not been confirmed terminal; preserving $tmp and test resources for recovery." >&2
            exit 1
        fi
    fi
    if [[ "$app_deleted" == false ]]; then
        rad app delete "$app_name" --workspace "$workspace" --yes || status=1
    fi
    if [[ "$status" -ne 0 && "$diagnostics_collected" == false ]]; then
        rtc_collect_test_diagnostics Radius.Data/postgreSqlDatabases "$app_name" "$started" ||
            echo "Error: PostgreSQL diagnostic collection failed after application cleanup failure." >&2
        diagnostics_collected=true
    fi
    rtc_cleanup_kubernetes_resources "$namespace" "$app_name" || status=1
    kubectl delete configmap -n "$namespace" -l "radapp.io/application=$app_name" || status=1
    kubectl delete secret -n "$namespace" -l "rtc-postgresql-test=$app_name" || status=1
    if [[ "$status" -ne 0 && "$diagnostics_collected" == false ]]; then
        rtc_collect_test_diagnostics Radius.Data/postgreSqlDatabases "$app_name" "$started" ||
            echo "Error: PostgreSQL diagnostic collection failed after Kubernetes cleanup failure." >&2
    fi
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
    local existing_type
    existing_type="$(kubectl get secret postgresql-tls -n "$namespace" --ignore-not-found -o jsonpath='{.type}')"
    kubectl create secret tls postgresql-tls -n "$namespace" \
        --cert="$tmp/server.crt" --key="$tmp/server.key" --dry-run=client -o json |
        jq --arg app "$app_name" --arg type "$existing_type" \
            '.metadata.labels = {"rtc-postgresql-test": $app} |
             if $type != "" then .type = $type else . end' |
        kubectl apply -f -
}
issue_certificate

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
    timeout "$deploy_timeout" rad deploy "$SCRIPT_DIR/app.bicep" --application "$app_name" \
        --workspace "$workspace" -e "$environment_id" --parameters "@$tmp/parameters.json"
}

wait_for_deployment() {
    local name="$1"
    kubectl rollout status deployment/"$name" -n "$namespace" --timeout="${rollout_timeout}s"
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
    local expected="$1" certificate_source="${2:-operator}" client fingerprint ca remote_ca local_ca plaintext_auth=reject
    wait_for_deployment postgresql
    wait_for_deployment democontainer
    kubectl get deployment postgresql -n "$namespace" -o json |
        jq -e '.spec.progressDeadlineSeconds == 600' >/dev/null
    client="$(kubectl get pods -n "$namespace" -l "radapp.io/application=$app_name,radapp.io/resource=democontainer" \
        -o json | jq -er '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name' | head -n1)"
    if [[ "$certificate_source" == generated ]]; then
        kubectl exec -n "$namespace" deployment/postgresql -- cat /tls-runtime/server.crt >"$tmp/client-ca.crt"
    else
        cp "$tmp/ca.crt" "$tmp/client-ca.crt"
    fi
    kubectl cp -n "$namespace" "$tmp/client-ca.crt" "$client:/tmp/postgresql-test-ca.crt"
    kubectl cp -n "$namespace" "$tmp/wrong-ca.crt" "$client:/tmp/postgresql-wrong-ca.crt"
    for ca in ca wrong-ca; do
        remote_ca=postgresql-test-ca
        if [[ "$ca" == wrong-ca ]]; then remote_ca=postgresql-wrong-ca; fi
        local_ca="$tmp/wrong-ca.crt"
        if [[ "$ca" == ca ]]; then local_ca="$tmp/client-ca.crt"; fi
        if [[ "$(kubectl exec -n "$namespace" "$client" -- sha256sum "/tmp/$remote_ca.crt" | cut -d' ' -f1)" != \
            "$(sha256sum "$local_ca" | cut -d' ' -f1)" ]]; then
            echo "Error: Client CA transfer did not preserve $ca.crt." >&2
            return 1
        fi
    done
    kubectl exec -i -n "$namespace" "$client" -- sh -s -- "$expected" "$certificate_source" <"$SCRIPT_DIR/verify-transport.sh"
    rtc_assert_postgresql_result "$app_name" "$workspace"
    rad resource show Radius.Data/postgreSqlDatabases postgresql --application "$app_name" \
        --workspace "$workspace" -o json |
        jq -e --arg expected "$expected" '.properties.tls == $expected' >/dev/null
    fingerprint="$(kubectl exec -n "$namespace" deployment/postgresql -- cat /tls-runtime/server.crt |
        openssl x509 -noout -fingerprint -sha256)"
    if [[ "$certificate_source" == operator ]]; then
        [[ "$fingerprint" == "$(openssl x509 -in "$tmp/server.crt" -noout -fingerprint -sha256)" ]]
    fi
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
    echo "==> PostgreSQL $recipe_kind generated-certificate lifecycle: ${policy:-omitted}"
    deploy "$policy"
    assert_transport "${policy:-required}" generated
    [[ -z "$(kubectl get secret postgresql-tls -n "$namespace" --ignore-not-found -o name)" ]]
done
generated_fingerprint="$(kubectl exec -n "$namespace" deployment/postgresql -- cat /tls-runtime/server.crt |
    openssl x509 -noout -fingerprint -sha256)"
pod="$(kubectl get pods -n "$namespace" -l radapp.io/resource=postgresql -o jsonpath='{.items[0].metadata.name}')"
restarts="$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
kubectl exec -n "$namespace" "$pod" -- sh -c 'kill -TERM 1'
kubectl wait pod/"$pod" -n "$namespace" \
    --for="jsonpath={.status.containerStatuses[0].restartCount}=$((restarts + 1))" --timeout=180s
assert_transport required generated
[[ "$generated_fingerprint" == "$(kubectl exec -n "$namespace" deployment/postgresql -- cat /tls-runtime/server.crt |
    openssl x509 -noout -fingerprint -sha256)" ]]

echo "==> An empty Secret also uses the generated development certificate"
kubectl create secret generic postgresql-tls -n "$namespace"
kubectl label secret postgresql-tls -n "$namespace" "rtc-postgresql-test=$app_name"
kubectl rollout restart deployment/postgresql -n "$namespace"
assert_transport required generated

echo "==> Operator certificate takes precedence after a Pod restart"
install_certificate
kubectl rollout restart deployment/postgresql -n "$namespace"
assert_transport required
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

settle_deployment() {
    local status=0
    if [[ -n "$deployment_pid" ]]; then
        wait "$deployment_pid" || status=$?
        deployment_pid=""
        printf '%s\n' "$status" >"$tmp/deploy-status"
    else
        status="$(cat "$tmp/deploy-status")"
    fi
    if [[ "$status" == 0 ]] || {
        [[ "$status" != 124 && "$status" != 137 ]] &&
            grep -q DeploymentFailed "$tmp/failed-deployment.log"
    }; then
        deployment_pending=false
        return 0
    fi
    return 1
}

wait_for_certificate_failure() {
    local deadline=$((SECONDS + certificate_timeout)) deployment_uid revision rs_uid pod_json
    while (( SECONDS < deadline )); do
        if ! kubectl get deployment postgresql -n "$namespace" --ignore-not-found -o json >"$tmp/deployment.json"; then
            return 1
        fi
        if [[ ! -s "$tmp/deployment.json" ]]; then sleep 2; continue; fi
        if ! jq -e '.status.observedGeneration == .metadata.generation and
            (.status.readyReplicas // 0) == 0 and (.status.availableReplicas // 0) == 0' \
            "$tmp/deployment.json" >/dev/null; then sleep 2; continue; fi
        deployment_uid="$(jq -r '.metadata.uid' "$tmp/deployment.json")"
        revision="$(jq -r '.metadata.annotations["deployment.kubernetes.io/revision"]' "$tmp/deployment.json")"
        rs_uid="$(kubectl get replicasets -n "$namespace" -l radapp.io/resource=postgresql -o json |
            jq -r --arg uid "$deployment_uid" --arg revision "$revision" \
            '.items[] | select(any(.metadata.ownerReferences[]?; .uid == $uid)) |
             select(.metadata.annotations["deployment.kubernetes.io/revision"] == $revision) | .metadata.uid')"
        pod_json="$(kubectl get pods -n "$namespace" -l radapp.io/resource=postgresql -o json |
            jq -c --arg uid "$rs_uid" '.items[] |
             select(.metadata.deletionTimestamp == null and any(.metadata.ownerReferences[]?; .uid == $uid)) |
             select(any(.status.initContainerStatuses[]?; .name == "prepare-tls" and
               (.state.waiting.reason == "CrashLoopBackOff" or
                ((.restartCount > 0) and (.lastState.terminated.exitCode // 0) != 0))))')"
        if [[ -n "$pod_json" ]]; then
            failed_pod="$(jq -r '.metadata.name' <<<"$pod_json")"
            failed_pod_uid="$(jq -r '.metadata.uid' <<<"$pod_json")"
            if kubectl logs -n "$namespace" "$failed_pod" -c prepare-tls --tail=40 >"$tmp/server-error.log" &&
                grep -q 'Error: PostgreSQL TLS Secret postgresql-tls' "$tmp/server-error.log"; then
                return 0
            fi
        fi
        sleep 2
    done
    echo "Error: Expected a certificate-specific init failure, not a Pending Pod, image-pull failure, or timeout." >&2
    return 1
}

for failure in partial malformed; do
    failed_pod=""
    failed_pod_uid=""
    echo "==> Checking $failure operator material fails initialization"
    kubectl delete secret postgresql-tls -n "$namespace" --ignore-not-found
    if [[ "$failure" == partial ]]; then
        kubectl create secret generic postgresql-tls -n "$namespace" \
            --from-file="tls.crt=$tmp/server.crt" --dry-run=client -o json |
            jq --arg app "$app_name" '.metadata.labels = {"rtc-postgresql-test": $app}' |
            kubectl apply -f -
    else
        kubectl create secret generic postgresql-tls -n "$namespace" \
            --from-literal=tls.crt=invalid --from-literal=tls.key=invalid --dry-run=client -o json |
            jq --arg app "$app_name" '.metadata.labels = {"rtc-postgresql-test": $app}' |
            kubectl apply -f -
    fi
    app_deleted=false
    deploy "" >"$tmp/failed-deployment.log" 2>&1 &
    deployment_pid=$!
    deployment_pending=true
    failure_status=0
    wait_for_certificate_failure || failure_status=$?
    # Repair while the provider waits, then let that invocation finish before cleanup.
    install_certificate
    if [[ -n "${failed_pod:-}" ]]; then
        live_uid="$(kubectl get pod "$failed_pod" -n "$namespace" --ignore-not-found -o jsonpath='{.metadata.uid}')"
        if [[ "$live_uid" == "$failed_pod_uid" ]]; then
            kubectl delete pod "$failed_pod" -n "$namespace" --wait=false
        fi
    fi
    settle_deployment || exit 1
    [[ "$(cat "$tmp/deploy-status")" == 0 ]] || deploy ""
    assert_transport required
    [[ "$failure_status" == 0 ]] || exit 1
    rad app delete "$app_name" --workspace "$workspace" --yes
    app_deleted=true
    rtc_cleanup_kubernetes_resources "$namespace" "$app_name"
    kubectl delete configmap -n "$namespace" -l "radapp.io/application=$app_name"
done
echo "PostgreSQL $recipe_kind certificate failure checks passed."

capture_update_baseline() {
    kubectl get deployment postgresql -n "$namespace" -o json >"$tmp/update-deployment.json" || return 1
    kubectl get pods -n "$namespace" -l radapp.io/resource=postgresql -o json >"$tmp/update-pods.json" || return 1
    kubectl get service postgresql -n "$namespace" -o json >"$tmp/update-service.json" || return 1
    jq -e --slurpfile pods "$tmp/update-pods.json" --slurpfile service "$tmp/update-service.json" '
      def count($replicas; $round):
        if type == "number" then .
        elif endswith("%") then (rtrimstr("%") | tonumber) * $replicas / 100 |
          if $round == "up" then ceil else floor end
        else tonumber end;
      select(.spec.replicas == 1 and .spec.strategy.type == "RollingUpdate") |
      select((.spec.strategy.rollingUpdate.maxUnavailable | count(1; "down")) == 0 and
             (.spec.strategy.rollingUpdate.maxSurge | count(1; "up")) >= 1) |
      select(.status.observedGeneration == .metadata.generation) |
      select($pods[0].items | length == 1) |
      $pods[0].items[0] as $pod |
      {deployment: .metadata.uid, generation: .metadata.generation,
       revision: (.metadata.annotations["deployment.kubernetes.io/revision"] | tonumber),
       pod: $pod.metadata.uid, podName: $pod.metadata.name, ip: $pod.status.podIP,
       restarts: ($pod.status.containerStatuses[] | select(.name == "postgres") | .restartCount),
       replicaSet: ($pod.metadata.ownerReferences[] | select(.controller == true) | .uid),
       service: $service[0].metadata.uid}
    ' "$tmp/update-deployment.json" >"$tmp/update-baseline.json" || {
        echo "Error: Failed-update test requires one replica and a RollingUpdate allowing surge with zero unavailable Pods." >&2
        return 1
    }
    assert_old_server || return 1
    echo "Failed-update baseline (object identities and serving address):"
    jq -c . "$tmp/update-baseline.json"
}

assert_old_server() {
    local pod_name
    pod_name="$(jq -er .podName "$tmp/update-baseline.json")" || return 1
    kubectl get pod "$pod_name" -n "$namespace" -o json >"$tmp/old-pod.json" || return 1
    kubectl get endpointslices -n "$namespace" -l kubernetes.io/service-name=postgresql \
        -o json >"$tmp/update-endpoints.json" || return 1
    jq -e --slurpfile baseline "$tmp/update-baseline.json" '
      $baseline[0] as $b |
      .metadata.uid == $b.pod and .metadata.deletionTimestamp == null and
      .status.podIP == $b.ip and
      any(.metadata.ownerReferences[]?; .uid == $b.replicaSet and .controller == true) and
      any(.status.conditions[]?; .type == "Ready" and .status == "True") and
      any(.status.containerStatuses[]?; .name == "postgres" and .ready == true and .restartCount == $b.restarts)
    ' "$tmp/old-pod.json" >/dev/null || return 1
    jq -e --slurpfile baseline "$tmp/update-baseline.json" '
      $baseline[0] as $b |
      (.items | length > 0) and
      all(.items[]; any(.metadata.ownerReferences[]?; .uid == $b.service and .kind == "Service")) and
      ([.items[].endpoints[]? | select(.conditions.ready == true)] |
       length == 1 and all(.[];
         .targetRef.kind == "Pod" and .targetRef.uid == $b.pod and
         .conditions.terminating != true and (.addresses | index($b.ip) != null)))
    ' "$tmp/update-endpoints.json" >/dev/null
}

wait_for_failed_update() {
    local deadline=$((SECONDS + certificate_timeout)) candidate
    while (( SECONDS < deadline )); do
        kubectl get deployment postgresql -n "$namespace" -o json >"$tmp/update-deployment.json" || return 1
        kubectl get replicasets -n "$namespace" -l radapp.io/resource=postgresql \
            -o json >"$tmp/update-replicasets.json" || return 1
        kubectl get pods -n "$namespace" -l radapp.io/resource=postgresql -o json >"$tmp/update-pods.json" || return 1
        candidate="$(jq -cer --slurpfile b "$tmp/update-baseline.json" \
            --slurpfile sets "$tmp/update-replicasets.json" --slurpfile pods "$tmp/update-pods.json" '
          $b[0] as $b |
          select(.metadata.uid == $b.deployment and .metadata.generation > $b.generation and
            .status.observedGeneration == .metadata.generation) |
          (.metadata.annotations["deployment.kubernetes.io/revision"] | tonumber) as $revision |
          select($revision > $b.revision) |
          select(any($sets[0].items[]; .metadata.uid == $b.replicaSet and
            (.metadata.annotations["deployment.kubernetes.io/revision"] | tonumber) == $b.revision and
            any(.metadata.ownerReferences[]?; .uid == $b.deployment and .controller == true))) |
          [$sets[0].items[] | select(.metadata.uid != $b.replicaSet and
            (.metadata.annotations["deployment.kubernetes.io/revision"] | tonumber) == $revision and
            any(.metadata.ownerReferences[]?; .uid == $b.deployment and .controller == true))] |
          select(length == 1) | .[0].metadata.uid as $newSet |
          select([$pods[0].items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
            .metadata.uid] == [$b.pod]) |
          [$pods[0].items[] | select(.metadata.deletionTimestamp == null and
            any(.metadata.ownerReferences[]?; .uid == $newSet and .controller == true)) |
            select(any(.status.initContainerStatuses[]?; .name == "prepare-tls" and
              (.state.waiting.reason == "CrashLoopBackOff" or
                (.restartCount > 0 and (.lastState.terminated.exitCode // 0) != 0))))] |
          select(length == 1) | .[0] | {name: .metadata.name, uid: .metadata.uid}
        ' "$tmp/update-deployment.json")" || candidate=""
        if [[ -n "$candidate" ]] && assert_old_server; then
            failed_pod="$(jq -r .name <<<"$candidate")"
            failed_pod_uid="$(jq -r .uid <<<"$candidate")"
            if kubectl logs -n "$namespace" "$failed_pod" -c prepare-tls --tail=40 >"$tmp/update-init.log" &&
                grep -q 'Error: PostgreSQL TLS Secret postgresql-tls' "$tmp/update-init.log"; then
                echo "Observed certificate failure in replacement Pod; the original optional Pod remains the sole ready Service endpoint."
                jq -c '{deployment: .metadata.uid, generation: .metadata.generation,
                  revision: .metadata.annotations["deployment.kubernetes.io/revision"]}' "$tmp/update-deployment.json"
                printf 'Failed replacement: %s\n' "$candidate"
                return 0
            fi
        fi
        sleep 2
    done
    echo "Error: Did not observe the expected failed update with the unchanged old serving Pod." >&2
    return 1
}

probe_old_server() {
    local mode="$1" expected="$2" client result deadline=$((SECONDS + 30)) old_ip
    old_ip="$(jq -er .ip "$tmp/update-baseline.json")" || return 1
    # Bicep can replace the client even when the database update cannot roll out.
    while :; do
        client="$(kubectl get pods -n "$namespace" \
            -l "radapp.io/application=$app_name,radapp.io/resource=democontainer" -o json |
            jq -r '[.items[] | select(.metadata.deletionTimestamp == null and
              any(.status.conditions[]?; .type == "Ready" and .status == "True"))] |
              first | .metadata.name // empty')" || return 1
        [[ -z "$client" ]] || break
        if (( SECONDS >= deadline )); then echo "Error: No ready client for failed-update probe." >&2; return 1; fi
        sleep 2
    done
    kubectl cp -n "$namespace" "$tmp/ca.crt" "$client:/tmp/postgresql-test-ca.crt" || return 1
    result="$(kubectl exec -n "$namespace" "$client" -- sha256sum /tmp/postgresql-test-ca.crt)" || return 1
    [[ "${result%% *}" == "$(sha256sum "$tmp/ca.crt" | cut -d' ' -f1)" ]] || return 1
    assert_old_server || return 1
    result="$(kubectl exec -n "$namespace" "$client" -- sh -ec '
        export PGHOST="$1" PGSSLMODE="$2" PGPORT="$CONNECTION_POSTGRESQL_PORT"
        export PGUSER="$CONNECTION_POSTGRESQL_USERNAME" PGDATABASE="$CONNECTION_POSTGRESQL_DATABASE"
        export PGPASSWORD="$CONNECTION_POSTGRESQL_PASSWORD" PGCONNECT_TIMEOUT=5
        export PGOPTIONS="-c statement_timeout=5000" PGSSLROOTCERT=/tmp/postgresql-test-ca.crt
        timeout 10 psql -X -w -Atc "SELECT ssl, inet_server_addr() FROM pg_stat_ssl WHERE pid = pg_backend_pid()"
    ' -- "$hostname" "$mode")" || return 1
    assert_old_server || return 1
    if [[ "$result" != "$expected|$old_ip" ]]; then
        echo "Error: Failed-update SQL did not confirm $mode transport from the recorded old Pod." >&2
        return 1
    fi
    echo "Service SQL confirmed $mode ssl=$expected and inet_server_addr=$old_ip from the unchanged old Pod."
}

echo "==> Checking failed optional-to-required update retains the old serving policy"
app_deleted=false
deployment_pid=""
deployment_pending=false
failed_pod=""
failed_pod_uid=""
deploy optional
assert_transport optional
capture_update_baseline
secret_identity="$(kubectl get secret postgresql-tls -n "$namespace" -o json |
    jq -c '{uid: .metadata.uid, version: .metadata.resourceVersion, type, owner: .metadata.labels["rtc-postgresql-test"]}')"
# Keep the Secret object, its type, and both key names; mutate only its material.
kubectl patch secret postgresql-tls -n "$namespace" --type merge \
    -p '{"data":{"tls.crt":"aW52YWxpZA==","tls.key":"aW52YWxpZA=="}}'
kubectl get secret postgresql-tls -n "$namespace" -o json |
    jq -e --argjson old "$secret_identity" --arg app "$app_name" '
      .metadata.uid == $old.uid and .metadata.resourceVersion != $old.version and .type == $old.type and
      .metadata.labels["rtc-postgresql-test"] == $old.owner and $old.owner == $app
    ' >/dev/null
deploy required >"$tmp/failed-deployment.log" 2>&1 &
deployment_pid=$!
deployment_pending=true
failure_status=0
if wait_for_failed_update; then
    probe_old_server disable f || failure_status=1
    probe_old_server verify-full t || failure_status=1
else
    failure_status=1
fi
# Recovery is unconditional, even when observation or SQL attribution failed.
recovery_status=0
install_certificate || recovery_status=1
if [[ -n "$failed_pod" ]]; then
    live_uid="$(kubectl get pod "$failed_pod" -n "$namespace" --ignore-not-found -o jsonpath='{.metadata.uid}')" || recovery_status=1
    if [[ "$live_uid" == "$failed_pod_uid" ]]; then
        kubectl delete pod "$failed_pod" -n "$namespace" --wait=false || recovery_status=1
    fi
fi
settle_deployment || exit 1
if [[ "$(cat "$tmp/deploy-status")" != 0 ]]; then
    deploy required >"$tmp/failed-deployment.log" 2>&1 &
    deployment_pid=$!
    deployment_pending=true
    settle_deployment || exit 1
    [[ "$(cat "$tmp/deploy-status")" == 0 ]] || {
        echo "Error: Required-policy recovery deployment failed." >&2
        exit 1
    }
fi
assert_transport required
old_pod_name="$(jq -r .podName "$tmp/update-baseline.json")"
[[ -z "$(kubectl get pod "$old_pod_name" -n "$namespace" --ignore-not-found -o name)" ]]
kubectl get secret postgresql-tls -n "$namespace" -o json |
    jq -e --argjson old "$secret_identity" '.metadata.uid == $old.uid and .type == $old.type and
      .metadata.labels["rtc-postgresql-test"] == $old.owner' >/dev/null
rad app delete "$app_name" --workspace "$workspace" --yes
app_deleted=true
kubectl get secret postgresql-tls -n "$namespace" -o name
[[ "$failure_status" == 0 && "$recovery_status" == 0 ]] || {
    echo "Error: Failed-update observation/probe or repair failed, despite completing recovery." >&2
    exit 1
}
echo "PostgreSQL $recipe_kind failed-update retention and required-policy recovery passed."
