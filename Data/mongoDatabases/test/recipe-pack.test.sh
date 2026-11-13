#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rtc-mongodb-pack-XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

for platform in kubernetes azure; do
    mkdir -p "$TEST_ROOT/Data/mongoDatabases/recipes/$platform/bicep" \
        "$TEST_ROOT/Data/mongoDatabases/recipes/$platform/terraform"
    touch "$TEST_ROOT/Data/mongoDatabases/recipes/$platform/bicep/main.bicep" \
        "$TEST_ROOT/Data/mongoDatabases/recipes/$platform/terraform/main.tf"
done

for platform in kubernetes azure; do
    for kind in bicep terraform; do
        output="$TEST_ROOT/$platform-$kind.bicep"
        RECIPE_PLATFORM_FILTER="$platform" bash "$REPO_ROOT/.github/scripts/generate-recipe-pack.sh" \
            "$TEST_ROOT" "${kind}recipepack" "$output" >/dev/null
        if [[ "$platform-$kind" == kubernetes-bicep ]]; then
            grep -q '^@secure()$' "$output"
            grep -q '^param mongoPassword string = newGuid()$' "$output"
            grep -q 'mongoPassword: mongoPassword' "$output"
        elif grep -q mongoPassword "$output"; then
            echo "Error: MongoDB password injection must affect only Kubernetes Bicep packs." >&2
            exit 1
        fi
    done
done
echo "MongoDB generated pack tests passed"
