#!/bin/bash
set -euo pipefail
umask 077

RECIPE_TYPE="${1:?Recipe kind required}"
case "$RECIPE_TYPE" in bicep|terraform) ;; *) echo "Unsupported recipe kind" >&2; exit 1 ;; esac
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
BASELINE_SHA=18142182e52e19a46b0ed172037357e8e142dcd2
CASE="postgresql-upgrade-$RECIPE_TYPE-$(date +%s)"
ORIGINAL_WORKSPACE="${2:-default}"
TMP_DIR="$(mktemp -d)"
GROUP_CREATED=false
MODULE_ADDED=false
FORWARD_PID=""
MODULE_NAMESPACE=radius-test-tf-module-server
MODULE_CONFIGMAP=tf-module-server-content
MODULE_NAME="postgreSqlDatabases-upgrade-${BASELINE_SHA:0:12}.zip"

cleanup() {
    local status=$? failed=0
    trap - EXIT
    if [[ -n "$FORWARD_PID" ]]; then
        if kill -0 "$FORWARD_PID" 2>/dev/null; then kill "$FORWARD_PID"; fi
        wait "$FORWARD_PID" 2>/dev/null || true
    fi
    if [[ "$GROUP_CREATED" == true ]]; then
        rad group delete "$CASE" --workspace "$ORIGINAL_WORKSPACE" --yes || failed=1
        kubectl delete namespace "$CASE" --ignore-not-found --timeout=120s || failed=1
    fi
    if [[ "$MODULE_ADDED" == true ]]; then
        kubectl patch configmap "$MODULE_CONFIGMAP" -n "$MODULE_NAMESPACE" --type=json \
            -p "[{\"op\":\"remove\",\"path\":\"/binaryData/$MODULE_NAME\"}]" || failed=1
    fi
    rad workspace switch "$ORIGINAL_WORKSPACE" || failed=1
    rm -rf "$TMP_DIR"
    if [[ "$status" -eq 0 && "$failed" -ne 0 ]]; then status=1; fi
    exit "$status"
}
trap cleanup EXIT

for tool in rad kubectl jq curl sha256sum; do
    command -v "$tool" >/dev/null
done
if [[ "$RECIPE_TYPE" == bicep ]]; then
    command -v oras >/dev/null
    OLD_SOURCE="ghcr.io/radius-project/kube-recipes/postgresqldatabases:$BASELINE_SHA"
    descriptor=$(oras manifest fetch --descriptor "$OLD_SOURCE")
    digest=$(jq -er '.digest' <<<"$descriptor")
    echo "==> Released Radius.Data/v0.3.0 baseline: source=$OLD_SOURCE digest=$digest commit=$BASELINE_SHA"
    NEW_SOURCE=reciperegistry:5000/radius-recipes/data/postgresqldatabases/kubernetes/bicep/kubernetes-postgresql:latest
else
    command -v zip >/dev/null
    if kubectl get configmap "$MODULE_CONFIGMAP" -n "$MODULE_NAMESPACE" -o json |
        jq -e --arg name "$MODULE_NAME" '.binaryData | has($name)' >/dev/null; then
        echo "Error: Baseline module key already exists; refusing overwrite." >&2
        exit 1
    fi
    mkdir "$TMP_DIR/source"
    curl -fsSL "https://github.com/radius-project/resource-types-contrib/archive/$BASELINE_SHA.tar.gz" |
        tar -xz --strip-components=1 -C "$TMP_DIR/source"
    module="$TMP_DIR/source/Data/postgreSqlDatabases/recipes/kubernetes/terraform"
    test -f "$module/main.tf"
    (cd "$module" && zip -qr "$TMP_DIR/$MODULE_NAME" .)
    expected_hash=$(sha256sum "$TMP_DIR/$MODULE_NAME" | cut -d' ' -f1)
    jq -n --arg name "$MODULE_NAME" --arg data "$(base64 -w0 <"$TMP_DIR/$MODULE_NAME")" \
        '{binaryData: {($name): $data}}' >"$TMP_DIR/patch.json"
    kubectl patch configmap "$MODULE_CONFIGMAP" -n "$MODULE_NAMESPACE" \
        --type=merge --patch-file "$TMP_DIR/patch.json"
    MODULE_ADDED=true
    kubectl rollout restart deployment/tf-module-server -n "$MODULE_NAMESPACE"
    kubectl rollout status deployment/tf-module-server -n "$MODULE_NAMESPACE" --timeout=120s
    kubectl port-forward -n "$MODULE_NAMESPACE" service/tf-module-server 0:80 \
        >"$TMP_DIR/forward.log" 2>&1 &
    FORWARD_PID=$!
    port=""
    for ((attempt=0; attempt<30; attempt++)); do
        port=$(sed -n 's/Forwarding from 127.0.0.1:\([0-9]*\).*/\1/p' "$TMP_DIR/forward.log" | head -1)
        if [[ -n "$port" ]]; then break; fi
        kill -0 "$FORWARD_PID"
        sleep 1
    done
    [[ -n "$port" ]] || { echo "Module-server port forward did not start" >&2; exit 1; }
    served_hash=$(curl -fsS "http://127.0.0.1:$port/$MODULE_NAME" | sha256sum | cut -d' ' -f1)
    [[ "$served_hash" == "$expected_hash" ]] || { echo "Served baseline checksum mismatch" >&2; exit 1; }
    echo "==> Pinned-source Terraform baseline: commit=$BASELINE_SHA served_sha256=$served_hash archive=$MODULE_NAME"
    OLD_SOURCE="http://tf-module-server.$MODULE_NAMESPACE.svc.cluster.local/$MODULE_NAME"
    NEW_SOURCE="http://tf-module-server.$MODULE_NAMESPACE.svc.cluster.local/postgreSqlDatabases-kubernetes.zip"
fi

rad group create "$CASE" --workspace "$ORIGINAL_WORKSPACE"
GROUP_CREATED=true
rad workspace create kubernetes "$CASE" --group "$CASE" --force
kubectl create namespace "$CASE"
rad env create "$CASE" --workspace "$CASE" --kubernetes-namespace "$CASE" --preview
environment_id=$(rad env show "$CASE" --workspace "$CASE" --preview -o json | jq -er '.id')
POSTGRESQL_UPGRADE_PACK="$CASE" POSTGRESQL_UPGRADE_OLD_SOURCE="$OLD_SOURCE" \
    POSTGRESQL_UPGRADE_NEW_SOURCE="$NEW_SOURCE" \
    bash "$TEST_DIR/test-tls.sh" "$RECIPE_TYPE" "$environment_id" "$CASE" "$CASE"
echo "==> $RECIPE_TYPE old-to-new Recipe upgrade and transport suite passed"
