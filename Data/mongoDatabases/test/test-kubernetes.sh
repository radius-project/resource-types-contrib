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

# The shared runner calls this assertion before deleting the test application.
rtc_assert_recipe_result() {
    local app_name="$2" namespace="$4" deployment
    local selector="radapp.io/application=$app_name,radapp.io/resource=democontainer"
    if ! kubectl wait deployment -n "$namespace" -l "$selector" \
        --for=condition=Available --timeout=180s; then
        echo "Error: MongoDB demo client is not available." >&2
        return 1
    fi
    if ! deployment=$(kubectl get deployment -n "$namespace" -l "$selector" -o json |
        jq -er 'if (.items | length) == 1 then .items[0].metadata.name else error("expected one demo deployment") end'); then
        echo "Error: Could not select the MongoDB demo client deployment." >&2
        return 1
    fi
    # shellcheck disable=SC2016 # $set is a literal MongoDB update operator.
    if ! kubectl exec -n "$namespace" "deployment/$deployment" -c demo -- node -e '
(async () => {
    const { MongoClient } = require("mongodb");
    const client = new MongoClient(process.env.MONGODB_CONNECTIONSTRING, {
        serverSelectionTimeoutMS: 10000,
        connectTimeoutMS: 10000,
        socketTimeoutMS: 10000
    });
    try {
        await client.connect();
        const collection = client.db("mongo_db").collection("radius_recipe_test");
        await collection.updateOne({_id: "connection"}, {$set: {value: "ok"}}, {upsert: true});
        const document = await collection.findOne({_id: "connection"});
        if (document?.value !== "ok") {
            throw new Error("MongoDB test value did not match.");
        }
    } finally {
        await client.close();
    }
})().catch(() => {
    console.error("MongoDB authenticated write/read failed.");
    process.exitCode = 1;
});
'; then
        echo "Error: MongoDB demo client could not write/read through its managed connection-string Secret." >&2
        return 1
    fi
    echo "==> MongoDB authenticated write/read passed"
}

rtc_deploy_and_assert_test_app "$SCRIPT_DIR/app.bicep" \
    Radius.Data/mongoDatabases mongorecipetest "$environment_path" "$workspace" "$namespace" \
    --parameters "mongoResourceName=$resource_name"
