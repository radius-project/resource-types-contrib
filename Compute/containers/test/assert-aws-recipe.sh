#!/bin/bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
BICEP="$HOME/.rad/bin/bicep"
PACK_PATH="$REPO_ROOT/recipe-packs/aws-eks/aws-eks.bicep"

# The AWS Recipe uses `extension aws`, which Bicep resolves through a
# bicepconfig.json, and calls the Kubernetes Recipe as a module, so compile a
# copy of both in a scratch directory.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/containers-aws-recipe-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/recipes"
cp -R "$TEST_DIR/../recipes/aws" "$TEST_DIR/../recipes/kubernetes" "$WORK_DIR/recipes/"
cat >"$WORK_DIR/bicepconfig.json" <<'EOF'
{
  "extensions": {
    "aws": "br:biceptypes.azurecr.io/aws:latest"
  }
}
EOF
TEMPLATE=$("$BICEP" build --stdout "$WORK_DIR/recipes/aws/bicep/aws-eks-containers.bicep")

# Connections must not turn the IAM policy into an environment variable.
jq -e '
  .resources.kube.properties.template.variables.excludedProperties |
  index("awsIamPolicy") != null
' <<<"$TEMPLATE" >/dev/null ||
    { echo "The Kubernetes containers Recipe must exclude awsIamPolicy from connection environment variables" >&2; exit 1; }

# Recipes of one Radius group deploy into one scope. A fixed nested deployment
# name lets concurrent containers read each other's outputs.
jq -e '
  .resources.kube.name | contains("parameters(\u0027context\u0027).resource.id")
' <<<"$TEMPLATE" >/dev/null ||
    { echo "The nested Kubernetes deployment name must be unique per Radius resource" >&2; exit 1; }

# The roles take the boundary's path, so one deploy identity grant on that path
# covers them, and the boundary is the only path input.
jq -e '
  .resources.role.properties.properties.Path == "[variables(\u0027rolePath\u0027)]" and
  .resources.role.properties.properties.PermissionsBoundary == "[parameters(\u0027appPermissionsBoundaryArn\u0027)]"
' <<<"$TEMPLATE" >/dev/null ||
    { echo "The IAM role must use the boundary and the boundary's path" >&2; exit 1; }

# The identity can't be optional. See the appPermissionsBoundaryArn comment in
# the Recipe.
jq -e '
  (.parameters.appPermissionsBoundaryArn | has("defaultValue") | not) and
  (.resources.role | has("condition") | not) and
  (.resources.association | has("condition") | not)
' <<<"$TEMPLATE" >/dev/null ||
    { echo "The AWS containers Recipe must always create its identity and require appPermissionsBoundaryArn" >&2; exit 1; }

# The aws-eks pack must pass every required Recipe parameter and nothing the
# Recipe does not declare.
# shellcheck source=.github/scripts/lib-recipe-packs.sh
source "$REPO_ROOT/.github/scripts/lib-recipe-packs.sh"
rtc_check_recipe_pack_params "$PACK_PATH" "Radius.Compute/containers" "$TEMPLATE"

rtc_recipe_pack_required_params "$PACK_PATH" | grep -qx appPermissionsBoundaryArn ||
    { echo "The aws-eks pack must require appPermissionsBoundaryArn" >&2; exit 1; }

echo "AWS containers Recipe and pack parameter contract test passed"
