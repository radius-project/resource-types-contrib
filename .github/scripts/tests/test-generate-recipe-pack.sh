#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
fixture="$TEMP/repo with spaces"
output="$TEMP/output with spaces"
mkdir -p "$output" "$fixture/recipe-packs/azure-aks"
cp "$ROOT/recipe-packs/azure-aks/azure-aks.bicep" "$fixture/recipe-packs/azure-aks/"
for platform in azure kubernetes azure-other; do
    mkdir -p "$fixture/Data/postgreSqlDatabases/recipes/$platform/bicep"
    touch "$fixture/Data/postgreSqlDatabases/recipes/$platform/bicep/main.bicep"
done
mkdir -p "$fixture/Data/postgreSqlDatabases/recipes/azure/terraform" "$fixture/Data/widgets/recipes/azure/bicep"
touch "$fixture/Data/postgreSqlDatabases/recipes/azure/terraform/main.tf" "$fixture/Data/widgets/recipes/azure/bicep/main.bicep"
source "$ROOT/.github/scripts/lib-recipe-packs.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

generate() {
    RECIPE_PLATFORM_FILTER="$1" bash "$ROOT/.github/scripts/generate-recipe-pack.sh" \
        "$fixture" "$2" "$output/generated.bicep" >/dev/null
}
generate azure azurebiceprecipepack
body="$(rtc_recipe_pack_entry_body "$output/generated.bicep" Radius.Data/postgreSqlDatabases)"
grep -Fq "source: 'reciperegistry:5000/radius-recipes/data/postgresqldatabases/azure/bicep/main:latest'" <<<"$body" || fail "local source"
grep -Fq 'plainHttp: true' <<<"$body" || fail "plain HTTP"
grep -Fq 'parameters: postgreSqlRecipeParameters(postgreSqlServerConfigurations)' <<<"$body" || fail "shared parameters"
grep -Fq 'outputs: postgreSqlRecipeOutputs' <<<"$body" || fail "shared outputs"
grep -Fq "from '../repo with spaces/recipe-packs/azure-aks/azure-aks.bicep'" "$output/generated.bicep" || fail "relative import"
[[ "$(grep -c '^import ' "$output/generated.bicep")" == 1 ]] || fail "duplicate import"
widgets="$(rtc_recipe_pack_entry_body "$output/generated.bicep" Radius.Data/widgets)"
! grep -Eq 'parameters:|outputs:' <<<"$widgets" || fail "unrelated recipe changed"

for spec in 'kubernetes biceprecipepack' 'azure terraformrecipepack' 'azure-other biceprecipepack'; do
    read -r platform pack <<<"$spec"
    generate "$platform" "$pack"
    ! grep -Eq '^(import |param postgreSql)|parameters:|outputs:' "$output/generated.bicep" ||
        fail "mapping leaked into $spec"
done
generate '' biceprecipepack
[[ "$(grep -c '^import ' "$output/generated.bicep")" == 1 ]] || fail "unfiltered discovery"

# The output path is relative to the caller, not to the fixture repository.
(
    cd "$TEMP"
    RECIPE_PLATFORM_FILTER=azure bash "$ROOT/.github/scripts/generate-recipe-pack.sh" \
        'repo with spaces' azurebiceprecipepack 'output with spaces/relative.bicep' >/dev/null
)
grep -Fq "from '../repo with spaces/recipe-packs/azure-aks/azure-aks.bicep'" "$output/relative.bicep" || fail "relative output"

mv "$fixture" "$TEMP/repo's \${literal}"
fixture="$TEMP/repo's \${literal}"
generate azure azurebiceprecipepack
grep -Fq "from '../repo\\'s \\\${literal}/recipe-packs/azure-aks/azure-aks.bicep'" "$output/generated.bicep" ||
    fail "Bicep path escaping"

rm "$fixture/recipe-packs/azure-aks/azure-aks.bicep"
if generate azure azurebiceprecipepack 2>"$TEMP/error"; then fail "missing canonical mapping accepted"; fi
grep -Fq 'canonical Azure mapping is missing' "$TEMP/error" || fail "missing mapping diagnostic"
echo "Recipe pack generator tests passed"
