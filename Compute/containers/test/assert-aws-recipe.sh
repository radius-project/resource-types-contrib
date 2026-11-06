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

# IAM role names are account-wide, and resource IDs repeat across installations.
jq -e '
  .variables.roleName |
  contains("parameters(\u0027eksClusterName\u0027)") and contains("variables(\u0027namespace\u0027)")
' <<<"$TEMPLATE" >/dev/null ||
    { echo "The IAM role name must depend on the EKS cluster and namespace" >&2; exit 1; }

# Radius doesn't delete resources a Recipe stops creating, so the identity
# can't be optional: clearing the boundary must fail instead of dropping it.
jq -e '
  (.parameters.appPermissionsBoundaryArn | has("defaultValue") | not) and
  (.resources.role | has("condition") | not) and
  (.resources.association | has("condition") | not)
' <<<"$TEMPLATE" >/dev/null ||
    { echo "The AWS containers Recipe must always create its identity and require appPermissionsBoundaryArn" >&2; exit 1; }

# The aws-eks pack must pass every required Recipe parameter and nothing the
# Recipe does not declare: a deployment rejects undeclared parameters.
# shellcheck source=.github/scripts/lib-recipe-packs.sh
source "$REPO_ROOT/.github/scripts/lib-recipe-packs.sh"
PACK_PARAMS=$(
    rtc_recipe_pack_entry_body "$PACK_PATH" "Radius.Compute/containers" |
        awk '
            /^[[:space:]]*parameters:[[:space:]]*\{[[:space:]]*$/ { inside = 1; next }
            inside && /^[[:space:]]*\}/ { inside = 0; next }
            inside && match($0, /^[[:space:]]*[A-Za-z0-9_]+:/) {
                key = substr($0, RSTART, RLENGTH - 1)
                gsub(/[[:space:]]/, "", key)
                print key
            }
        ' | jq -Rsc 'split("\n") | map(select(length > 0)) | sort'
)
jq -e --argjson passed "$PACK_PARAMS" '
  (.parameters | del(.context)) as $params |
  ($params | with_entries(select(.value | has("defaultValue") | not)) | keys | sort) as $required |
  ($required - $passed) == [] and
  ($passed - ($params | keys)) == []
' <<<"$TEMPLATE" >/dev/null ||
    { echo "aws-eks pack parameters $PACK_PARAMS do not match the AWS containers Recipe parameters" >&2; exit 1; }

rtc_recipe_pack_required_params "$PACK_PATH" | grep -qx appPermissionsBoundaryArn ||
    { echo "The aws-eks pack must require appPermissionsBoundaryArn" >&2; exit 1; }

echo "AWS containers Recipe and pack parameter contract test passed"
