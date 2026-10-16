#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEMP="$(mktemp -d)"
suffix="$$-$(date +%s)"
canonical_name="pg-canonical-$suffix"
generated_name="pggenerated${suffix//-/}"
created=()
cleanup() {
    local status=$?
    trap - EXIT
    for name in "${created[@]}"; do rad recipe-pack delete "$name" --yes || status=1; done
    rm -rf "$TEMP"
    exit "$status"
}
trap cleanup EXIT
export RADIUS_PREVIEW=true
BICEP="${BICEP_COMMAND:-$HOME/.rad/bin/bicep}"
fixture="$TEMP/repo's \${literal} with spaces"
output="$TEMP/output with spaces"
mkdir -p "$fixture/recipe-packs/azure-aks" "$fixture/Data/postgreSqlDatabases/recipes/azure/bicep" "$output"
cp "$ROOT/recipe-packs/azure-aks/azure-aks.bicep" "$fixture/recipe-packs/azure-aks/"
cp "$ROOT/Data/postgreSqlDatabases/recipes/azure/bicep/azure-postgresql.bicep" \
    "$fixture/Data/postgreSqlDatabases/recipes/azure/bicep/"
if [[ -f "$ROOT/bicepconfig.json" ]]; then
    jq '{extensions:{radius:.extensions.radius}}' "$ROOT/bicepconfig.json" > "$TEMP/bicepconfig.json"
else
    printf '%s\n' '{"extensions":{"radius":"br:biceptypes.azurecr.io/radius:latest"}}' > "$TEMP/bicepconfig.json"
fi
canonical="$fixture/recipe-packs/azure-aks/azure-aks.bicep"
sed -i "s/name: 'azure-aks'/name: '$canonical_name'/" "$canonical"
RECIPE_PLATFORM_FILTER=azure bash "$ROOT/.github/scripts/generate-recipe-pack.sh" \
    "$fixture" "$generated_name" "$output/generated.bicep"

"$BICEP" build "$canonical" --outfile "$TEMP/canonical.json"
"$BICEP" build "$output/generated.bicep" --outfile "$TEMP/generated.json"
"$BICEP" build "$fixture/Data/postgreSqlDatabases/recipes/azure/bicep/azure-postgresql.bicep" --outfile "$TEMP/wrapper.json"
jq -e '(.parameters | keys) == ["postgreSqlServerConfigurations"] and (.resources | length) == 1' \
    "$TEMP/generated.json" >/dev/null
# Both consumers must call the shared exports, not maintain equal-looking copies.
for file in "$canonical" "$output/generated.bicep"; do
    grep -Fq 'parameters: postgreSqlRecipeParameters(postgreSqlServerConfigurations)' "$file"
    grep -Fq 'outputs: postgreSqlRecipeOutputs' "$file"
done

derived='{{context.resource.properties.tls == "optional" ? "OFF" : "ON"}}'
deploy_pack() {
    if ! timeout 90 rad deploy "$1" -e "${RAD_ENVIRONMENT_NAME:-default}" \
        -p "@$2" > "$TEMP/deploy.log" 2>&1; then
        echo "Error: Test Recipe Pack deployment failed." >&2
        cat "$TEMP/deploy.log" >&2
        exit 1
    fi
}
first=true
for configs in '[]' \
    '[{"name":"require_secure_transport","source":"user-override","value":"ON"}]' \
    '[{"name":"require_secure_transport","source":"user-override","value":"OFF"}]' \
    '[{"name":"azure.extensions","value":"VECTOR"}]' \
    '[{"name":"Require_Secure_Transport","value":"OFF"}]' \
    '[{"value":"no name"}]'; do
    jq -n --argjson configs "$configs" '{parameters:{postgreSqlServerConfigurations:{value:$configs}}}' \
        > "$TEMP/generated.parameters.json"
    jq '.parameters.routesGatewayName={value:"fixture"} | .parameters.containerImagesRegistry={value:"fixture"}' \
        "$TEMP/generated.parameters.json" > "$TEMP/canonical.parameters.json"
    deploy_pack "$TEMP/canonical.json" "$TEMP/canonical.parameters.json"
    if [[ "$first" == true ]]; then created+=("$canonical_name"); fi
    deploy_pack "$TEMP/generated.json" "$TEMP/generated.parameters.json"
    if [[ "$first" == true ]]; then created+=("$generated_name"); fi
    first=false
    rad recipe-pack show "$canonical_name" -o json | jq '.properties.recipes["Radius.Data/postgreSqlDatabases"]' > "$TEMP/canonical-entry.json"
    rad recipe-pack show "$generated_name" -o json | jq '.properties.recipes["Radius.Data/postgreSqlDatabases"]' > "$TEMP/generated-entry.json"
    jq -e --slurpfile canonical "$TEMP/canonical-entry.json" --slurpfile wrapper "$TEMP/wrapper.json" \
        --argjson configs "$configs" --arg derived "$derived" '
      .parameters == $canonical[0].parameters and .outputs == $canonical[0].outputs and
      (.parameters | keys) == ($wrapper[0].parameters | keys) and
      .outputs == {host:"fqdn"} and .parameters.tlsPolicy == "{{context.resource.properties.tls}}" and
      .parameters.administratorLoginPassword == "{{context.resource.properties.password}}" and
      .source == "reciperegistry:5000/radius-recipes/data/postgresqldatabases/azure/bicep/azure-postgresql:latest" and
      .plainHttp == true and
      $canonical[0].source == "ghcr.io/radius-project/azure-recipes/postgresqldatabases:latest" and
      .parameters.configurations == ($configs + (if any($configs[]; .name? == "require_secure_transport")
        then [] else [{name:"require_secure_transport",source:"user-override",value:$derived}] end))
    ' "$TEMP/generated-entry.json" >/dev/null || {
        echo "Error: Generated PostgreSQL mapping mismatch for configurations: $configs" >&2
        exit 1
    }
done

sed -i '/^@export()/d' "$canonical"
if "$BICEP" build "$output/generated.bicep" --outfile "$TEMP/missing-export.json" > "$TEMP/error" 2>&1; then
    echo "Error: Missing canonical exports compiled successfully." >&2
    exit 1
fi
grep -Fq 'not exported' "$TEMP/error"
echo "Generated Azure PostgreSQL mappings match the canonical pack for all configuration cases"
