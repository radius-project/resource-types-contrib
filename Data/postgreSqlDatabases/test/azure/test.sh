#!/bin/bash
set -euo pipefail
umask 077
[[ "${2:?Recipe kind required}" == bicep ]] || { echo "Error: Azure PostgreSQL requires Bicep." >&2; exit 1; }
ENVIRONMENT="${3:?Environment required}"
ENVIRONMENT_NAME="${ENVIRONMENT##*/}"
WORKSPACE="${4:?Workspace required}"
SUBSCRIPTION="${AZURE_SUBSCRIPTION_ID:-}"
GROUP="${AZURE_RESOURCE_GROUP:?Use an isolated CI Azure resource group}"
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
TEST_DIR="$ROOT/Data/postgreSqlDatabases/test/azure"
for tool in az rad jq openssl; do
    command -v "$tool" >/dev/null || { echo "Error: Missing Azure acceptance tool: $tool" >&2; exit 1; }
done
if ! command -v psql >/dev/null || ! command -v pg_dump >/dev/null; then
    if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted ]]; then
        echo "Error: Install psql and pg_dump before running Azure acceptance tests." >&2
        exit 1
    fi
    sudo apt-get update -qq
    sudo apt-get install -y postgresql-client
fi
if ! environment_state=$(rad env show "$ENVIRONMENT_NAME" --workspace "$WORKSPACE" -o json); then
    echo "Error: Could not read the Azure test Environment." >&2; exit 1
fi
if ! provider_scope=$(jq -er '
    .properties.providers.azure |
    select((.subscriptionId | type) == "string" and (.resourceGroupName | type) == "string") |
    select((.subscriptionId | length) > 0 and (.resourceGroupName | length) > 0) |
    "/subscriptions/\(.subscriptionId)/resourceGroups/\(.resourceGroupName)"
' <<<"$environment_state"); then
    echo "Error: Azure test Environment has no valid subscription/resource group." >&2; exit 1
fi
if [[ -z "$SUBSCRIPTION" ]]; then
    if ! SUBSCRIPTION=$(az account show --query id -o tsv); then
        echo "Error: Could not read the authenticated Azure subscription." >&2; exit 1
    fi
fi
if [[ ! "$SUBSCRIPTION" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] ||
    [[ "${provider_scope,,}" != "/subscriptions/${SUBSCRIPTION,,}/resourcegroups/${GROUP,,}" ]]; then
    echo "Error: Azure test subscription/resource group does not match the Environment provider scope." >&2
    exit 1
fi
TMP="$(mktemp -d "$ROOT/.postgresql-azure-test-XXXXXX")"
APP="postgresql-azure-$(date +%s)-$$"
PACK="$APP-pack"
RESOURCE_CREATED=false
PACK_CREATED=false
ENV_CHANGED=false
SERVER_ID=""
ORIGINAL_PACKS=$(printf '%s' "$environment_state" |
    jq -er '.properties.recipePacks | select(length > 0) | map(split("/")[-1]) | join(",")')
snapshot() {
    az postgres flexible-server list --subscription "$SUBSCRIPTION" --resource-group "$GROUP" -o json
}
snapshot >"$TMP/original.json"
cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$RESOURCE_CREATED" == true ]]; then
        for type in Radius.Data/postgreSqlDatabases Radius.Core/applications Applications.Core/applications; do
            if ids=$(rad resource list "$type" --workspace "$WORKSPACE" -o json |
                jq -er --arg name "$APP" '[.[] | select(.name == $name)] | length'); then
                if [[ "$ids" == 1 ]]; then
                    rad resource delete "$type" "$APP" --workspace "$WORKSPACE" --yes || status=1
                elif [[ "$ids" != 0 ]]; then
                    echo "Error: Ambiguous Azure test resource ownership." >&2
                    status=1
                fi
            else
                status=1
            fi
        done
    fi
    if [[ "$ENV_CHANGED" == true ]]; then
        rad env update "$ENVIRONMENT_NAME" --workspace "$WORKSPACE" --recipe-packs "$ORIGINAL_PACKS" || status=1
    fi
    if [[ "$PACK_CREATED" == true ]]; then
        rad recipe-pack delete "$PACK" --workspace "$WORKSPACE" --yes || status=1
    fi
    snapshot >"$TMP/final.json" || status=1
    diff -u <(jq -S 'sort_by(.id)' "$TMP/original.json") <(jq -S 'sort_by(.id)' "$TMP/final.json") || {
        echo "Error: Azure test cleanup leaked a server or changed an unrelated server." >&2
        status=1
    }
    rm -f "$TMP/"*.json "$TMP/"*.log "$TMP/backup.sql" "$TMP/generated.bicep"
    rmdir "$TMP"
    exit "$status"
}
trap cleanup EXIT

# Compile the actual checked-in pack; modify only its test name and PostgreSQL entry.
"$HOME/.rad/bin/bicep" build --stdout "$ROOT/recipe-packs/azure-aks/azure-aks.bicep" >"$TMP/pack.json"
jq --arg pack "$PACK" '.resources.azureAksRecipePack.properties.name = $pack' \
    "$TMP/pack.json" >"$TMP/baseline.json"
jq --arg pack "$PACK" '
    .resources.azureAksRecipePack.properties.name = $pack |
    .resources.azureAksRecipePack.properties.properties.recipes["Radius.Data/postgreSqlDatabases"] = {
      kind:"bicep",
      source:"reciperegistry:5000/radius-recipes/data/postgresqldatabases/azure/bicep/azure-postgresql:latest",
      plainHttp:true, parameters:{postgreSqlServerConfigurations:[]}
    }
' "$TMP/pack.json" >"$TMP/candidate.json"
activate() {
    local -a parameters=()
    if jq -e '.parameters | has("routesGatewayName")' "$1" >/dev/null; then
        parameters+=(-p routesGatewayName=validation-gateway -p containerImagesRegistry=localhost:5000)
    fi
    PACK_CREATED=true
    rad deploy "$1" --workspace "$WORKSPACE" -e "$ENVIRONMENT" "${parameters[@]}"
    ENV_CHANGED=true
    rad env update "$ENVIRONMENT_NAME" --workspace "$WORKSPACE" --recipe-packs "$PACK"
}
# A protected ARM parameter file avoids passing the generated password in argv.
openssl rand -hex 24 | jq -Rs --arg app "$APP" \
    '{parameters:{password:{value:rtrimstr("\n")},applicationName:{value:$app}}}' >"$TMP/parameters.json"
deploy() {
    RESOURCE_CREATED=true
    rad deploy "$TEST_DIR/app.bicep" --application "$APP" --workspace "$WORKSPACE" \
        -e "$ENVIRONMENT" -p "@$TMP/parameters.json" -p "tlsPolicy=$1"
}
resource_state() {
    rad resource show Radius.Data/postgreSqlDatabases "$APP" --workspace "$WORKSPACE" -o json
}
query() {
    PGHOST="$HOST" PGUSER=radadmin PGDATABASE=appdb PGSSLMODE=require PGCONNECT_TIMEOUT=15 \
        PGPASSWORD="$(jq -r '.parameters.password.value' "$TMP/parameters.json")" \
        psql -X -w -At -v ON_ERROR_STOP=1 -c "$1"
}
server_settings() {
    snapshot | jq -Se --arg id "$SERVER_ID" '
      [.[] | select((.id | ascii_downcase) == ($id | ascii_downcase))] |
      select(length == 1) | .[0] |
      {id, name, location, version, sku, storage, highAvailability, network, administratorLogin}
    '
}
tracked_server() {
    jq -er '[.properties.status.outputResources[] | .. | strings |
      select(test("/providers/Microsoft.DBforPostgreSQL/flexibleServers/[^/]+$"; "i"))] |
      unique | select(length == 1) | .[0]'
}
assert_disabled_rejection() {
    local rejected_at scope
    rejected_at=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    scope="${SERVER_ID:-/subscriptions/$SUBSCRIPTION/resourceGroups/$GROUP/providers/Microsoft.DBforPostgreSQL/}"
    snapshot >"$TMP/before.json"
    if deploy disabled >"$TMP/rejection.log" 2>&1; then
        echo "Error: Azure accepted unsupported policy disabled." >&2; exit 1
    fi
    snapshot >"$TMP/after.json"
    bash "$TEST_DIR/assert-rejection.sh" "$TMP/rejection.log" "$TMP/before.json" "$TMP/after.json"
    az monitor activity-log list --subscription "$SUBSCRIPTION" --resource-group "$GROUP" \
        --start-time "$rejected_at" --max-events 1000 -o json >"$TMP/rejection-activity.json"
    jq -e --arg id "$scope" '
      all(.[]; ((.resourceId // "" | ascii_downcase | startswith($id | ascii_downcase)) | not) or
        ((.operationName.value // "" | ascii_downcase | test("/(write|delete)$")) | not))
    ' "$TMP/rejection-activity.json" >/dev/null || {
        echo "Error: Azure unsupported policy mutated the server." >&2; exit 1;
    }
}
activate "$TMP/candidate.json"
assert_disabled_rejection
for override in ON OFF; do
    jq --arg value "$override" '
      .resources.azureAksRecipePack.properties.properties.recipes["Radius.Data/postgreSqlDatabases"].parameters.postgreSqlServerConfigurations =
        [{name:"require_secure_transport",source:"user-override",value:$value}]
    ' "$TMP/candidate.json" >"$TMP/override.json"
    activate "$TMP/override.json"
    assert_disabled_rejection
done
activate "$TMP/baseline.json"
deploy default
resource_state >"$TMP/before-resource.json"
SERVER_ID=$(tracked_server <"$TMP/before-resource.json")
echo "Azure migration prior tracked resource IDs:"
jq '[.properties.status.outputResources[] | .. | strings | select(test("^/(subscriptions|planes)/"; "i"))] | unique' \
    "$TMP/before-resource.json"
HOST=$(jq -er '.properties.host' "$TMP/before-resource.json")
server_settings >"$TMP/baseline-settings.json"
query 'CREATE TABLE radius_migration_marker (id integer); INSERT INTO radius_migration_marker VALUES (73)' >/dev/null
PGHOST="$HOST" PGUSER=radadmin PGDATABASE=appdb PGSSLMODE=require PGCONNECT_TIMEOUT=15 \
    PGPASSWORD="$(jq -r '.parameters.password.value' "$TMP/parameters.json")" \
    pg_dump --no-owner --no-privileges --table=radius_migration_marker >"$TMP/backup.sql"
[[ -s "$TMP/backup.sql" ]] || { echo "Error: Azure migration backup was empty." >&2; exit 1; }
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
activate "$TMP/candidate.json"
for policy in default default required optional; do
    deploy "$policy"
    resource_state >"$TMP/after-resource.json"
    echo "Azure migration current tracked resource IDs ($policy):"
    jq '[.properties.status.outputResources[] | .. | strings | select(test("^/(subscriptions|planes)/"; "i"))] | unique' \
        "$TMP/after-resource.json"
    [[ "$(tracked_server <"$TMP/after-resource.json")" == "$SERVER_ID" ]] || {
        echo "Error: Azure migration changed the exact tracked server ID." >&2; exit 1;
    }
    [[ "$(query 'SELECT id FROM radius_migration_marker')" == 73 ]] || {
        echo "Error: Azure migration lost data." >&2; exit 1;
    }
    server_settings >"$TMP/current-settings.json"
    diff -u "$TMP/baseline-settings.json" "$TMP/current-settings.json" || {
        echo "Error: Azure migration changed existing server settings." >&2; exit 1;
    }
    transport=on
    [[ "$policy" != optional ]] || transport=off
    [[ "$(query 'SHOW require_secure_transport')" == "$transport" ]] || {
        echo "Error: Azure supported policy did not set the requested transport." >&2; exit 1;
    }
    # Driver GC compares exact IDs. Only obsolete deployment records may disappear.
    jq -e --slurpfile previous "$TMP/before-resource.json" '
      def ids: [.properties.status.outputResources[] | .. | strings |
        select(test("^/(subscriptions|planes)/"; "i"))] | unique;
      (ids) as $current | ($previous[0] | ids) - $current |
      all(.[]; test("/providers/Microsoft.Resources/deployments/"; "i"))
    ' "$TMP/after-resource.json" >/dev/null || {
        echo "Error: Azure migration stopped tracking a prior non-deployment resource." >&2; exit 1;
    }
done
RECIPE_PLATFORM_FILTER=azure bash "$ROOT/.github/scripts/generate-recipe-pack.sh" \
    "$ROOT" "$PACK" "$TMP/generated.bicep" >/dev/null
"$HOME/.rad/bin/bicep" build --stdout "$TMP/generated.bicep" >"$TMP/generated.json"
activate "$TMP/generated.json"
deploy default
resource_state >"$TMP/generated-resource.json"
[[ "$(tracked_server <"$TMP/generated-resource.json")" == "$SERVER_ID" ]] || {
    echo "Error: Generated Azure pack changed the tracked server." >&2; exit 1;
}
[[ "$(query 'SELECT id FROM radius_migration_marker')" == 73 ]] || {
    echo "Error: Generated Azure pack lost migration data." >&2; exit 1;
}
activate "$TMP/candidate.json"
assert_disabled_rejection
[[ "$(query 'SELECT id FROM radius_migration_marker')" == 73 ]] || {
    echo "Error: Azure rejection lost migration data." >&2; exit 1;
}
for override in ON OFF; do
    jq --arg value "$override" '
      .resources.azureAksRecipePack.properties.properties.recipes["Radius.Data/postgreSqlDatabases"].parameters.postgreSqlServerConfigurations =
        [{name:"require_secure_transport",source:"user-override",value:$value}]
    ' "$TMP/candidate.json" >"$TMP/override.json"
    activate "$TMP/override.json"
    for policy in required optional; do
        deploy "$policy"
        [[ "$(query 'SHOW require_secure_transport')" == "${override,,}" ]] || {
            echo "Error: Azure operator transport precedence changed." >&2; exit 1;
        }
    done
    assert_disabled_rejection
    [[ "$(query 'SELECT id FROM radius_migration_marker')" == 73 ]]
done
az monitor activity-log list --subscription "$SUBSCRIPTION" --resource-group "$GROUP" \
    --start-time "$started" --max-events 1000 -o json >"$TMP/activity.json"
jq -e --arg id "$SERVER_ID" '
  all(.[]; ((.resourceId // "" | ascii_downcase) != ($id | ascii_downcase)) or
    ((.operationName.value // "" | ascii_downcase | endswith("/delete")) | not))
' "$TMP/activity.json" >/dev/null || { echo "Error: Azure migration deleted the server." >&2; exit 1; }
echo "Azure PostgreSQL actual-pack migration, rejection, and data checks passed; cleanup follows"
