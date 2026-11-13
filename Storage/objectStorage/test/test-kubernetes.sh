#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/lib-recipe-test.sh
source "$SCRIPT_DIR/../../../.github/scripts/lib-recipe-test.sh"

workspace="${1:-default}"
environment="${2:-default}"
rtc_ensure_workspace_context "$workspace"
resolved="$(rtc_resolve_environment_path "$environment" "$workspace")"
IFS=$'\t' read -r environment_id namespace <<<"$resolved"
if [[ -z "$namespace" ]]; then
    echo "Error: Kubernetes namespace is required." >&2
    exit 1
fi

resource_name="store-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
secret_name="$resource_name-blob-credentials"
secret_created=false
cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$secret_created" == true ]]; then
        if ! kubectl delete secret "$secret_name" --namespace "$namespace" \
            --request-timeout=10s --wait=false --ignore-not-found; then
            echo "Error: Could not remove test credentials Secret $secret_name." >&2
            status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

# Pipe credentials directly to Kubernetes. Never put them in process arguments,
# Recipe Pack parameters, or application parameters.
python3 - "$secret_name" "$namespace" <<'PY' |
import base64
import json
import secrets
import sys

key = base64.b64encode(secrets.token_bytes(64))
print(json.dumps({
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": sys.argv[1], "namespace": sys.argv[2]},
    "type": "Opaque",
    "data": {"accountKey": base64.b64encode(key).decode("ascii")},
}))
PY
    kubectl create --namespace "$namespace" --request-timeout=30s -f - -o name
secret_created=true

RTC_TEST_PLATFORM=kubernetes rtc_deploy_and_assert_test_app \
    "$SCRIPT_DIR/kubernetes/app.bicep" Radius.Storage/objectStorage \
    "$resource_name" "$environment_id" "$workspace" "$namespace" \
    --parameters "objectStorageResourceName=$resource_name"
