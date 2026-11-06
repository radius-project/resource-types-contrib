#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 "$root/.github/scripts/tests/test-postgresql-certificates.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/psql" <<'EOF'
#!/bin/sh
if [ "${TLS_FAIL:-0}" = 1 ]; then
    echo 'connection timed out' >&2
    exit 1
fi
if [ "$PGSSLROOTCERT" = /tmp/postgresql-no-ca.crt ] && [ "$PGSSLMODE" = verify-full ]; then
    echo 'root certificate file does not exist' >&2
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
    sh "$root/Data/postgreSqlDatabases/test/verify-transport.sh" "$@" >"$tmp/output" 2>&1
}
export CONNECTION_POSTGRESQL_TLS=required
probe required
probe required generated
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

sed -n '/^settle_deployment()/,/^}/p; /^wait_for_certificate_failure()/,/^}/p' \
    "$root/Data/postgreSqlDatabases/test/test-kubernetes.sh" >"$tmp/lifecycle-functions"
sed -n '/^capture_update_baseline()/,/^}/p; /^assert_old_server()/,/^}/p; /^wait_for_failed_update()/,/^}/p; /^probe_old_server()/,/^}/p' \
    "$root/Data/postgreSqlDatabases/test/test-kubernetes.sh" >>"$tmp/lifecycle-functions"
# shellcheck source=/dev/null
source "$tmp/lifecycle-functions"
export OBSERVER_FIXTURE="$tmp"
cat >"$tmp/bin/kubectl" <<'EOF'
#!/bin/bash
case "$1 $2" in
    "get deployment") cat "$OBSERVER_FIXTURE/observed-deployment.json" ;;
    "get replicasets") cat "$OBSERVER_FIXTURE/replicasets.json" ;;
    "get pods") cat "$OBSERVER_FIXTURE/pods.json" ;;
    "get pod") cat "$OBSERVER_FIXTURE/old-pod.json.fixture" ;;
    "get service") cat "$OBSERVER_FIXTURE/service.json" ;;
    "get endpointslices") cat "$OBSERVER_FIXTURE/endpoints.json" ;;
    "cp "*) echo cp >>"$OBSERVER_FIXTURE/probe-calls" ;;
    "exec "*)
        if [[ "$*" == *sha256sum* ]]; then
            sha256sum "$OBSERVER_FIXTURE/ca.crt"
        else
            echo sql >>"$OBSERVER_FIXTURE/probe-calls"
            [[ "${SQL_FAIL:-0}" != 1 ]] || exit 1
            if [[ "${POST_SQL_RESTART:-0}" == 1 ]]; then
                jq '.status.containerStatuses[0].restartCount = 1' "$OBSERVER_FIXTURE/healthy-old-pod.json" \
                    >"$OBSERVER_FIXTURE/old-pod.json.fixture"
            fi
            printf '%s\n' "${SQL_RESULT:-f|10.0.0.1}"
        fi ;;
    "logs "*) cat "$OBSERVER_FIXTURE/init.log" ;;
    *) echo "Error: unexpected Kubernetes observation: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/kubectl"
export namespace=isolated certificate_timeout=1
for state in failed-init stale-generation ready wrong-revision wrong-owner deleting pending image-pull wrong-log; do
    failed_pod=""
    failed_pod_uid=""
    jq -n --arg state "$state" '{
      metadata: {uid: "deployment", generation: 2, annotations: {"deployment.kubernetes.io/revision": "1"}},
      status: {observedGeneration: (if $state == "stale-generation" then 1 else 2 end),
               readyReplicas: (if $state == "ready" then 1 else 0 end), availableReplicas: 0}
    }' >"$tmp/observed-deployment.json"
    jq -n --arg state "$state" '{items: [{metadata: {
      uid: "replicaset", ownerReferences: [{uid: "deployment"}],
      annotations: {"deployment.kubernetes.io/revision": (if $state == "wrong-revision" then "0" else "1" end)}
    }}]}' >"$tmp/replicasets.json"
    jq -n --arg state "$state" '{items: [{
      metadata: {name: "failed-pod", uid: "pod",
        ownerReferences: [{uid: (if $state == "wrong-owner" then "unrelated" else "replicaset" end)}],
        deletionTimestamp: (if $state == "deleting" then "now" else null end)},
      status: {initContainerStatuses: [{name: "prepare-tls", restartCount: 0,
        state: {waiting: {reason: (if $state == "pending" then "PodInitializing"
          elif $state == "image-pull" then "ImagePullBackOff" else "CrashLoopBackOff" end)}}}]}
    }]}' >"$tmp/pods.json"
    if [[ "$state" == wrong-log ]]; then
        echo 'unrelated init error' >"$tmp/init.log"
    else
        echo 'Error: PostgreSQL TLS Secret postgresql-tls contains an invalid certificate/key pair.' >"$tmp/init.log"
    fi
    if wait_for_certificate_failure >"$tmp/observer.log" 2>&1; then
        [[ "$state" == failed-init ]] || {
            echo "Error: Certificate observer accepted $state." >&2
            exit 1
        }
        [[ "$failed_pod" == failed-pod && "$failed_pod_uid" == pod ]]
    elif [[ "$state" == failed-init ]]; then
        cat "$tmp/observer.log" >&2
        exit 1
    fi
done
export app_name=fixture hostname=postgresql.isolated.svc.cluster.local
cat >"$tmp/update-baseline.json" <<'EOF'
{"deployment":"deployment","generation":1,"revision":1,"replicaSet":"old-set",
 "pod":"old-pod","podName":"old-pod-name","ip":"10.0.0.1","restarts":0,"service":"service"}
EOF
for state in retained stale-generation unchanged-generation changed-deployment same-revision missing-revision wrong-owner \
    changed-old-set changed-old-pod deleting-old unready-old restarted-old extra-endpoint wrong-service \
    ready-new ready-new-endpoint deleting-new image-pull wrong-log; do
    jq -n --arg state "$state" '{
      metadata: {uid: (if $state == "changed-deployment" then "unrelated" else "deployment" end),
        generation: (if $state == "unchanged-generation" then 1 else 2 end),
        annotations: {"deployment.kubernetes.io/revision":
          (if $state == "same-revision" then "1" else "2" end)}},
      status: {observedGeneration: (if $state == "stale-generation" then 1 else 2 end)}
    }' >"$tmp/observed-deployment.json"
    jq -n --arg state "$state" '{items: [
      {metadata: {uid: (if $state == "changed-old-set" then "other-set" else "old-set" end),
        ownerReferences: [{uid: "deployment", controller: true}],
        annotations: {"deployment.kubernetes.io/revision": "1"}}},
      {metadata: {uid: "new-set",
        ownerReferences: [{uid: (if $state == "wrong-owner" then "unrelated" else "deployment" end), controller: true}],
        annotations: {"deployment.kubernetes.io/revision":
          (if $state == "missing-revision" then "3" else "2" end)}}}
    ]}' >"$tmp/replicasets.json"
    jq -n --arg state "$state" '{
      metadata: {name: "old-pod-name", uid: (if $state == "changed-old-pod" then "other-pod" else "old-pod" end),
        deletionTimestamp: (if $state == "deleting-old" then "now" else null end),
        ownerReferences: [{uid: "old-set", controller: true}]},
      status: {podIP: "10.0.0.1", conditions: [{type: "Ready",
        status: (if $state == "unready-old" then "False" else "True" end)}],
        containerStatuses: [{name: "postgres", ready: true,
          restartCount: (if $state == "restarted-old" then 1 else 0 end)}]}
    }' >"$tmp/old-pod.json.fixture"
    jq -n --slurpfile old "$tmp/old-pod.json.fixture" --arg state "$state" '{items: [$old[0], {
      metadata: {name: "new-pod-name", uid: "new-pod", ownerReferences: [{uid: "new-set", controller: true}],
        deletionTimestamp: (if $state == "deleting-new" then "now" else null end)},
      status: {conditions: [{type: "Ready", status: (if $state == "ready-new" then "True" else "False" end)}],
        initContainerStatuses: [{name: "prepare-tls", restartCount: 0,
          state: {waiting: {reason: (if $state == "image-pull" then "ImagePullBackOff" else "CrashLoopBackOff" end)}}}]}
    }]}' >"$tmp/pods.json"
    jq -n --arg state "$state" '{items: [{
      metadata: {ownerReferences: [{kind: "Service", uid: (if $state == "wrong-service" then "other" else "service" end)}]},
      endpoints: ([
        {targetRef: {kind: "Pod", uid: "old-pod"}, addresses: ["10.0.0.1"], conditions: {ready: true}},
        {targetRef: {kind: "Pod", uid: "new-pod"}, addresses: ["10.0.0.2"],
          conditions: {ready: ($state == "ready-new-endpoint")}}
      ] + (if $state == "extra-endpoint" then
        [{targetRef: {kind: "Pod", uid: "other"}, addresses: ["10.0.0.3"], conditions: {ready: true}}] else [] end))
    }]}' >"$tmp/endpoints.json"
    if [[ "$state" == wrong-log ]]; then
        echo unrelated >"$tmp/init.log"
    else
        echo 'Error: PostgreSQL TLS Secret postgresql-tls contains an invalid certificate/key pair.' >"$tmp/init.log"
    fi
    if wait_for_failed_update >"$tmp/observer.log" 2>&1; then
        [[ "$state" == retained ]] || { echo "Error: Failed-update observer accepted $state." >&2; exit 1; }
        [[ "$failed_pod" == new-pod-name && "$failed_pod_uid" == new-pod ]]
        cp "$tmp/old-pod.json.fixture" "$tmp/healthy-old-pod.json"
        cp "$tmp/endpoints.json" "$tmp/healthy-endpoints.json"
    elif [[ "$state" == retained ]]; then
        cat "$tmp/observer.log" >&2
        exit 1
    fi
done
cp "$tmp/healthy-old-pod.json" "$tmp/old-pod.json.fixture"
cp "$tmp/healthy-endpoints.json" "$tmp/endpoints.json"
echo '{"metadata":{"uid":"service"}}' >"$tmp/service.json"
jq -n --slurpfile old "$tmp/healthy-old-pod.json" '{items:$old}' >"$tmp/pods.json"
cp "$tmp/update-baseline.json" "$tmp/baseline.fixture"
for strategy in percentage integer unavailable no-surge multiple-replicas recreate; do
    jq -n --arg strategy "$strategy" '{
      metadata: {uid:"deployment",generation:1,annotations:{"deployment.kubernetes.io/revision":"1"}},
      status: {observedGeneration:1},
      spec: {replicas:(if $strategy == "multiple-replicas" then 2 else 1 end),
        strategy: {type:(if $strategy == "recreate" then "Recreate" else "RollingUpdate" end),
          rollingUpdate:{
            maxUnavailable:(if $strategy == "unavailable" then 1 elif $strategy == "integer" then 0 else "25%" end),
            maxSurge:(if $strategy == "no-surge" then "0%" elif $strategy == "integer" then 1 else "25%" end)}}}
    }' >"$tmp/observed-deployment.json"
    if capture_update_baseline >"$tmp/strategy.log" 2>&1; then
        [[ "$strategy" == percentage || "$strategy" == integer ]] || {
            echo "Error: Baseline accepted unsupported rolling-update strategy $strategy." >&2
            exit 1
        }
    elif [[ "$strategy" == percentage || "$strategy" == integer ]]; then
        cat "$tmp/strategy.log" >&2
        exit 1
    fi
done
cp "$tmp/baseline.fixture" "$tmp/update-baseline.json"
echo public-test-ca >"$tmp/ca.crt"
echo '{"items":[{"metadata":{"name":"ready-client"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' >"$tmp/pods.json"
probe_old_server disable f
SQL_RESULT='t|10.0.0.1' probe_old_server verify-full t
for result in 'f|10.0.0.2' 't|10.0.0.1'; do
    if SQL_RESULT="$result" probe_old_server disable f; then
        echo "Error: Failed-update probe accepted incorrect server/transport attribution." >&2
        exit 1
    fi
done
if SQL_FAIL=1 probe_old_server disable f; then
    echo "Error: Failed-update probe accepted an SQL error." >&2
    exit 1
fi
if POST_SQL_RESTART=1 probe_old_server disable f; then
    echo "Error: Failed-update probe accepted a Pod restart during SQL." >&2
    exit 1
fi
jq '.status.containerStatuses[0].restartCount = 1' "$tmp/healthy-old-pod.json" >"$tmp/old-pod.json.fixture"
if probe_old_server disable f; then
    echo "Error: Failed-update probe accepted an old Pod restart." >&2
    exit 1
fi
[[ "$(grep -c '^cp$' "$tmp/probe-calls")" == 7 ]]
[[ "$(grep -c '^sql$' "$tmp/probe-calls")" == 6 ]]
echo "PostgreSQL failed-update observer and Service SQL attribution tests passed."

export deployment_pid=""
for outcome in success terminal-error timeout killed unknown; do
    deployment_pending=true
    : >"$tmp/failed-deployment.log"
    case "$outcome" in
        success) echo 0 >"$tmp/deploy-status" ;;
        terminal-error) echo 1 >"$tmp/deploy-status"; echo DeploymentFailed >"$tmp/failed-deployment.log" ;;
        timeout) echo 124 >"$tmp/deploy-status"; echo DeploymentFailed >"$tmp/failed-deployment.log" ;;
        killed) echo 137 >"$tmp/deploy-status"; echo DeploymentFailed >"$tmp/failed-deployment.log" ;;
        unknown) echo 1 >"$tmp/deploy-status" ;;
    esac
    if settle_deployment; then
        [[ "$outcome" == success || "$outcome" == terminal-error ]] && [[ "$deployment_pending" == false ]] || {
            echo "Error: Accepted an uncertain deployment outcome: $outcome." >&2
            exit 1
        }
    else
        [[ "$outcome" != success && "$outcome" != terminal-error && "$deployment_pending" == true ]] || exit 1
    fi
done
rm "$tmp/bin/kubectl"
echo "PostgreSQL certificate failure observation and deployment settlement tests passed."

sed -n '/^cleanup()/,/^}/p' "$root/Data/postgreSqlDatabases/test/test-kubernetes.sh" >"$tmp/cleanup-function"
# shellcheck source=/dev/null
source "$tmp/cleanup-function"
# shellcheck disable=SC2329 # Stubs are called by the extracted cleanup trap.
for outcome in test-failure app-cleanup kubernetes-cleanup unsettled success; do
    export CLEANUP_CALLS="$tmp/cleanup-calls"
    : >"$CLEANUP_CALLS"
    status=0
    (
        export app_name=fixture workspace=fixture namespace=isolated started=2026-11-06T00:00:00Z
        export app_deleted=false deployment_pending=false
        [[ "$outcome" != unsettled ]] || deployment_pending=true
        rtc_collect_test_diagnostics() { echo collector >>"$CLEANUP_CALLS"; return 1; }
        settle_deployment() { return 1; }
        rad() { echo app-delete >>"$CLEANUP_CALLS"; [[ "$outcome" != app-cleanup ]]; }
        rtc_cleanup_kubernetes_resources() {
            echo namespace-delete >>"$CLEANUP_CALLS"
            [[ "$outcome" != kubernetes-cleanup ]]
        }
        kubectl() { echo extra-delete >>"$CLEANUP_CALLS"; }
        rm() { echo temporary-cleanup >>"$CLEANUP_CALLS"; }
        trap cleanup EXIT
        if [[ "$outcome" == test-failure ]]; then exit 7; fi
        exit 0
    ) >"$tmp/cleanup-output" 2>&1 || status=$?
    if [[ "$outcome" == success ]]; then
        [[ "$status" == 0 ]] || { cat "$tmp/cleanup-output" >&2; exit 1; }
        if grep -q '^collector$' "$CLEANUP_CALLS"; then
            echo "Error: Successful PostgreSQL cleanup must not collect diagnostics." >&2
            exit 1
        fi
    else
        expected=1
        [[ "$outcome" != test-failure ]] || expected=7
        [[ "$status" == "$expected" && "$(grep -c '^collector$' "$CLEANUP_CALLS")" == 1 ]] || {
            echo "Error: PostgreSQL $outcome must retain failure and collect once." >&2
            exit 1
        }
        if [[ "$outcome" == test-failure && "$(head -n1 "$CLEANUP_CALLS")" != collector ]]; then
            echo "Error: PostgreSQL diagnostics must precede failed-test cleanup." >&2
            exit 1
        fi
        if [[ "$outcome" == unsettled && "$(wc -l <"$CLEANUP_CALLS")" != 1 ]]; then
            echo "Error: Unsettled deployment must retain resources after collection." >&2
            exit 1
        fi
    fi
done
echo "PostgreSQL lifecycle failure diagnostics tests passed."

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
chmod +x "$fixture/Data/postgreSqlDatabases/test/test-kubernetes.sh"
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
    rm Data/postgreSqlDatabases/test/test-kubernetes.sh
    if bash .github/scripts/test-recipe-pack-entry.sh \
        Data/postgreSqlDatabases test-ws isolated verify-postgresql-transport >"$tmp/missing" 2>&1; then
        echo "Error: Explicit transport mode accepted missing historical test sources." >&2
        exit 1
    fi
    grep -q 'transport lifecycle is not available' "$tmp/missing"
    cat >>.github/scripts/lib-recipe-test.sh <<'EOF'
rtc_deploy_and_assert_test_app() {
    echo "legacy" >>"$DISPATCH_LOG"
}
EOF
    bash .github/scripts/test-recipe.sh Data/postgreSqlDatabases/recipes/kubernetes/bicep isolated
)
diff -u <(printf 'test-ws isolated bicep\ntest-ws isolated terraform\ntest-ws isolated bicep\ntest-ws isolated bicep\nlegacy\n') "$DISPATCH_LOG"
echo "PostgreSQL recipe dispatch tests passed."
