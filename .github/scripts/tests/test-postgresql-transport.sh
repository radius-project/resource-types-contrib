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
# shellcheck source=/dev/null
source "$tmp/lifecycle-functions"
export OBSERVER_FIXTURE="$tmp"
cat >"$tmp/bin/kubectl" <<'EOF'
#!/bin/bash
case "$1 $2" in
    "get deployment") cat "$OBSERVER_FIXTURE/observed-deployment.json" ;;
    "get replicasets") cat "$OBSERVER_FIXTURE/replicasets.json" ;;
    "get pods") cat "$OBSERVER_FIXTURE/pods.json" ;;
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
