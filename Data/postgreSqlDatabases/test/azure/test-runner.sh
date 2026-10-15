#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
assertion="$ROOT/Data/postgreSqlDatabases/test/azure/assert-rejection.sh"
printf '%s\n' 'Azure PostgreSQL does not support this tls policy. Use required or optional; disabled is Kubernetes-only.' >"$TMP/expected.log"
printf '%s\n' 'AuthenticationFailed' >"$TMP/unrelated.log"
echo '[]' >"$TMP/empty.json"
echo '[{"id":"existing","name":"unchanged"}]' >"$TMP/before.json"
echo '[{"id":"existing","name":"changed"}]' >"$TMP/changed.json"
echo '{}' >"$TMP/invalid.json"
bash "$assertion" "$TMP/expected.log" "$TMP/empty.json" "$TMP/empty.json"
bash "$assertion" "$TMP/expected.log" "$TMP/before.json" "$TMP/before.json"
for failure in unrelated changed invalid; do
    log="$TMP/expected.log"
    after="$TMP/before.json"
    case "$failure" in
        unrelated) log="$TMP/unrelated.log" ;;
        changed) after="$TMP/changed.json" ;;
        invalid) after="$TMP/invalid.json" ;;
    esac
    if bash "$assertion" "$log" "$TMP/before.json" "$after" >"$TMP/output.log" 2>&1; then
        echo "Error: Azure rejection assertion accepted $failure evidence." >&2; exit 1
    fi
done
RECIPE_PLATFORM_FILTER=azure bash "$ROOT/.github/scripts/list-recipe-folders.sh" "$ROOT" bicep |
    grep -Fxq "$ROOT/Data/postgreSqlDatabases/recipes/azure/bicep"
RECIPE_PLATFORM_FILTER=azure bash "$ROOT/.github/scripts/generate-recipe-pack.sh" \
    "$ROOT" azurebiceprecipepack "$TMP/generated.bicep" >/dev/null
grep -Fq 'reciperegistry:5000/radius-recipes/data/postgresqldatabases/azure/bicep/azure-postgresql:latest' "$TMP/generated.bicep"
mkdir "$TMP/bin"
cat >"$TMP/bin/rad" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$CALLS"
EOF
chmod +x "$TMP/bin/rad"
(
    cd "$ROOT"
    CALLS="$TMP/calls" PATH="$TMP/bin:$PATH" bash .github/scripts/register-recipe.sh \
        Data/postgreSqlDatabases/recipes/azure/bicep >/dev/null
)
grep -Fq -- '--workspace azure --environment azure --resource-type Radius.Data/postgreSqlDatabases --template-kind bicep --template-path reciperegistry:5000/radius-recipes/data/postgresqldatabases/azure/bicep/azure-postgresql:latest' "$TMP/calls"
echo "Azure PostgreSQL rejection evidence, discovery, and registration tests passed"

mkdir -p "$TMP/home/.rad/bin"
cat >"$TMP/home/.rad/bin/bicep" <<'EOF'
#!/bin/bash
echo '{"parameters":{"routesGatewayName":{},"containerImagesRegistry":{}},"resources":{"azureAksRecipePack":{"properties":{"name":"test","properties":{"recipes":{}}}}}}'
EOF
cat >"$TMP/bin/rad" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$1 $2" in
    "env show") echo '{"properties":{"recipePacks":["original-pack"]}}' ;;
    "env update"|"recipe-pack delete") ;;
    "deploy "*)
        if [[ "$2" == *.json ]]; then
            jq -r '.resources.azureAksRecipePack.properties.properties.recipes["Radius.Data/postgreSqlDatabases"].parameters.postgreSqlServerConfigurations[0].value // ""' "$2" >"$STATE/override"
            exit 0
        fi
        policy=default
        for arg in "$@"; do
            [[ "$arg" != tlsPolicy=* ]] || policy="${arg#*=}"
        done
        if [[ "$policy" == disabled ]]; then
            [[ ! -f "$STATE/server" ]] || touch "$STATE/rejected"
            if [[ "$SCENARIO" == unrelated ]]; then
                echo AuthenticationFailed >&2
            else
                echo 'Azure PostgreSQL does not support this tls policy. Use required or optional; disabled is Kubernetes-only.' >&2
            fi
            exit 1
        fi
        printf '%s' "$policy" >"$STATE/policy"
        while (( $# )); do
            if [[ "$1" == --application ]]; then printf '%s' "$2" >"$STATE/app"; break; fi
            shift
        done
        touch "$STATE/server"
        ;;
    "resource show")
        echo '{"properties":{"host":"test.invalid","status":{"outputResources":[{"id":"/subscriptions/test/resourceGroups/owned/providers/Microsoft.DBforPostgreSQL/flexibleServers/server"}]}}}'
        ;;
    "resource list")
        if [[ -f "$STATE/server" && "$3" == Radius.Data/postgreSqlDatabases ]]; then
            jq -n --arg name "$(cat "$STATE/app")" '[{name:$name}]'
        else echo '[]'; fi
        ;;
    "resource delete")
        [[ "$SCENARIO" != cleanup ]] || { echo 'fixture cleanup failure' >&2; exit 1; }
        rm "$STATE/server"
        ;;
    *) echo "Unexpected rad arguments: $*" >&2; exit 1 ;;
esac
EOF
cat >"$TMP/bin/az" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$1 $2" in
    "postgres flexible-server")
        if [[ -f "$STATE/server" ]]; then
            changed=false
            [[ "$SCENARIO" != changed || ! -f "$STATE/rejected" ]] || changed=true
            jq -n --argjson changed "$changed" '[{id:"/subscriptions/test/resourceGroups/owned/providers/Microsoft.DBforPostgreSQL/flexibleServers/server",changed:$changed}]'
        else echo '[]'; fi
        ;;
    "monitor activity-log")
        if [[ "$SCENARIO" == mutation && -f "$STATE/rejected" ]]; then
            echo '[{"resourceId":"/subscriptions/test/resourceGroups/owned/providers/Microsoft.DBforPostgreSQL/flexibleServers/server","operationName":{"value":"Microsoft.DBforPostgreSQL/flexibleServers/write"}}]'
        else echo '[]'; fi
        ;;
    *) echo "Unexpected az arguments: $*" >&2; exit 1 ;;
esac
EOF
cat >"$TMP/bin/psql" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$*" in
    *"CREATE TABLE"*) ;;
    *"SELECT id"*) echo 73 ;;
    *"SHOW require_secure_transport"*)
        value=$(cat "$STATE/override")
        if [[ -z "$value" ]]; then
            value=ON
            [[ "$(cat "$STATE/policy")" != optional ]] || value=OFF
        fi
        echo "${value,,}"
        ;;
    *) echo "Unexpected psql arguments: $*" >&2; exit 1 ;;
esac
EOF
cat >"$TMP/bin/pg_dump" <<'EOF'
#!/bin/bash
echo 'fixture backup'
EOF
chmod +x "$TMP/bin/"* "$TMP/home/.rad/bin/bicep"
for scenario in success unrelated changed mutation cleanup; do
    mkdir "$TMP/$scenario"
    status=0
    STATE="$TMP/$scenario" SCENARIO="$scenario" PATH="$TMP/bin:$PATH" HOME="$TMP/home" \
        AZURE_SUBSCRIPTION_ID=fixture AZURE_RESOURCE_GROUP=owned \
        bash "$ROOT/Data/postgreSqlDatabases/test/azure/test.sh" unused bicep \
        /planes/radius/local/resourceGroups/default/providers/Applications.Core/environments/azure azure \
        >"$TMP/$scenario.log" 2>&1 || status=$?
    if [[ "$scenario" == success ]]; then
        [[ "$status" == 0 ]] || { cat "$TMP/$scenario.log"; exit 1; }
        grep -Fq 'actual-pack migration, rejection, and data checks passed' "$TMP/$scenario.log"
    else
        [[ "$status" != 0 ]] || { echo "Error: Azure hook accepted $scenario failure." >&2; exit 1; }
        case "$scenario" in
            unrelated) expected='unsupported-policy diagnostic' ;;
            changed) expected='changed PostgreSQL server state' ;;
            mutation) expected='unsupported policy mutated' ;;
            cleanup) expected='fixture cleanup failure' ;;
        esac
        grep -Fq "$expected" "$TMP/$scenario.log" || { cat "$TMP/$scenario.log"; exit 1; }
    fi
done
echo "Azure full-hook fixtures passed: migration/overrides/rejection/cleanup success and 4 failures (not live proof)"
