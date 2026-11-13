#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=.github/scripts/lib-recipe-test.sh
source "$REPO_ROOT/.github/scripts/lib-recipe-test.sh"

workspace="${1:-default}"
environment="${2:-default}"
rtc_ensure_workspace_context "$workspace"
if ! resolved=$(rtc_resolve_environment_path "$environment" "$workspace"); then
    exit 1
fi
IFS=$'\t' read -r environment_path namespace <<<"$resolved"
if ! suffix=$(openssl rand -hex 6) || ! password=$(openssl rand -hex 32); then
    echo "Error: Could not generate MongoDB test credentials." >&2
    exit 1
fi
resource_name="mongo-$suffix"
secret_name="$resource_name-mongodb-credentials"
created=false

cleanup() {
    local status=$?
    if [[ "$created" == true ]]; then
        if ! kubectl delete secret "$secret_name" -n "$namespace" --ignore-not-found >/dev/null; then
            echo "Error: Could not remove MongoDB test credential Secret $secret_name." >&2
            status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

# Send the password over stdin, never through resource parameters or argv.
if ! printf '%s' "$password" |
    jq -Rs --arg name "$secret_name" --arg namespace "$namespace" \
        '{apiVersion:"v1",kind:"Secret",metadata:{name:$name,namespace:$namespace},type:"Opaque",stringData:{password:.}}' |
    kubectl create -f - >/dev/null; then
    echo "Error: Could not create MongoDB test credential Secret $secret_name." >&2
    exit 1
fi
created=true
unset password

rtc_deploy_and_assert_test_app "$SCRIPT_DIR/kubernetes/app.bicep" \
    Radius.Data/mongoDatabases mongorecipetest "$environment_path" "$workspace" "$namespace" \
    --parameters "mongoResourceName=$resource_name"
