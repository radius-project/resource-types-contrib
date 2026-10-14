#!/bin/bash
set -euo pipefail
umask 077

RECIPE_TYPE="${1:?Recipe kind required}"
case "$RECIPE_TYPE" in bicep|terraform) ;; *) echo "Unsupported recipe kind" >&2; exit 1 ;; esac
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
BASELINE_SHA=18142182e52e19a46b0ed172037357e8e142dcd2
BASELINE_DIGEST=sha256:ca65f43501f39fc31689e8a292e9e0e3179e4ebf7a89ec0143c12b4a1dc24ddd
EXECUTION_WORKSPACE="${2:-default}"
ORIGINAL_WORKSPACE=""
TMP_DIR="$(mktemp -d -t "postgresql-upgrade-$RECIPE_TYPE-XXXXXXXXXX")"
CASE="$(basename "$TMP_DIR" | tr '[:upper:]' '[:lower:]')"
GROUP_CREATED=false
WORKSPACE_CREATED=false
NAMESPACE_CREATED=false
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
        rad group delete "$CASE" --workspace "$EXECUTION_WORKSPACE" --yes || failed=1
    fi
    if [[ "$NAMESPACE_CREATED" == true ]]; then
        kubectl delete namespace "$CASE" --ignore-not-found --timeout=120s || failed=1
    fi
    if [[ "$MODULE_ADDED" == true ]]; then
        kubectl patch configmap "$MODULE_CONFIGMAP" -n "$MODULE_NAMESPACE" --type=json \
            -p "[{\"op\":\"remove\",\"path\":\"/binaryData/$MODULE_NAME\"}]" || failed=1
    fi
    if [[ "$WORKSPACE_CREATED" == true ]]; then
        if rad workspace switch "$ORIGINAL_WORKSPACE"; then
            rad workspace delete "$CASE" --yes || failed=1
        else
            echo "Error: Could not restore workspace $ORIGINAL_WORKSPACE; retaining owned workspace $CASE." >&2
            failed=1
        fi
    fi
    rm -rf "$TMP_DIR"
    if [[ "$failed" -ne 0 ]]; then echo "Error: Upgrade cleanup did not complete." >&2; fi
    if [[ "$status" -eq 0 && "$failed" -ne 0 ]]; then status=1; fi
    exit "$status"
}
trap cleanup EXIT

for tool in rad kubectl jq curl sha256sum; do
    command -v "$tool" >/dev/null || { echo "Error: $tool is required." >&2; exit 1; }
done

# Radius excludes workspace names from JSON. Read the named table column, not
# whitespace-delimited fields (which could silently truncate an unsupported name).
workspace_names() {
    awk '
        NR == 1 {
            if ($0 !~ /^WORKSPACE[[:space:]]+KIND[[:space:]]+KUBECONTEXT[[:space:]]+GROUP[[:space:]]+ENVIRONMENT[[:space:]]*$/) exit 1
            width = index($0, "KIND") - 1
            next
        }
        NF {
            name = substr($0, 1, width)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            if (name !~ /^[a-zA-Z0-9_.-]+$/) exit 1
            print name
        }
        END { if (NR == 0) exit 1 }
    '
}
current_table=$(rad workspace show -o table)
if ! ORIGINAL_WORKSPACE=$(workspace_names <<<"$current_table") ||
    [[ -z "$ORIGINAL_WORKSPACE" || "$ORIGINAL_WORKSPACE" == *$'\n'* ]]; then
    echo "Error: Cannot determine the current named Radius workspace; no resources were created." >&2
    exit 1
fi
workspace_table=$(rad workspace list -o table)
if ! names=$(workspace_names <<<"$workspace_table"); then
    echo "Error: Cannot read Radius workspace names safely." >&2
    exit 1
fi
if grep -Fxq "$CASE" <<<"$names"; then
    echo "Error: Upgrade workspace already exists; refusing overwrite." >&2
    exit 1
fi

if [[ "$RECIPE_TYPE" == bicep ]]; then
    command -v oras >/dev/null
    OLD_SOURCE="ghcr.io/radius-project/kube-recipes/postgresqldatabases:$BASELINE_SHA"
    descriptor=$(oras manifest fetch --descriptor "$OLD_SOURCE")
    digest=$(jq -er '.digest' <<<"$descriptor")
    if [[ "$digest" != "$BASELINE_DIGEST" ]]; then
        echo "Error: Released baseline digest mismatch: expected $BASELINE_DIGEST, got $digest." >&2
        exit 1
    fi
    OLD_SOURCE="ghcr.io/radius-project/kube-recipes/postgresqldatabases@$BASELINE_DIGEST"
    echo "==> Released Radius.Data/v0.3.0 baseline: source=$OLD_SOURCE digest=$digest commit=$BASELINE_SHA"
    NEW_SOURCE=reciperegistry:5000/radius-recipes/data/postgresqldatabases/kubernetes/bicep/kubernetes-postgresql:latest
else
    command -v zip >/dev/null
    module_configmap=$(kubectl get configmap "$MODULE_CONFIGMAP" -n "$MODULE_NAMESPACE" -o json)
    if jq -e --arg name "$MODULE_NAME" '(.binaryData // {}) | has($name)' <<<"$module_configmap" >/dev/null; then
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

groups=$(rad group list --workspace "$EXECUTION_WORKSPACE" -o json)
if ! jq -e --arg name "$CASE" 'type == "array" and all(.[]; (.name | type) == "string" and .name != $name)' <<<"$groups" >/dev/null; then
    echo "Error: Cannot establish that the upgrade resource group is absent." >&2
    exit 1
fi
namespace=$(kubectl get namespace "$CASE" --ignore-not-found -o name)
if [[ -n "$namespace" ]]; then
    echo "Error: Upgrade namespace already exists; refusing reuse." >&2
    exit 1
fi
rad group create "$CASE" --workspace "$EXECUTION_WORKSPACE"
GROUP_CREATED=true
rad workspace create kubernetes "$CASE" --group "$CASE"
WORKSPACE_CREATED=true
kubectl create namespace "$CASE"
NAMESPACE_CREATED=true
rad env create "$CASE" --workspace "$CASE" --kubernetes-namespace "$CASE" --preview
environment_id=$(rad env show "$CASE" --workspace "$CASE" --preview -o json | jq -er '.id')
POSTGRESQL_UPGRADE_PACK="$CASE" POSTGRESQL_UPGRADE_OLD_SOURCE="$OLD_SOURCE" \
    POSTGRESQL_UPGRADE_NEW_SOURCE="$NEW_SOURCE" \
    bash "$TEST_DIR/test-tls.sh" "$RECIPE_TYPE" "$environment_id" "$CASE" "$CASE"
echo "==> $RECIPE_TYPE old-to-new Recipe upgrade and transport suite passed"
