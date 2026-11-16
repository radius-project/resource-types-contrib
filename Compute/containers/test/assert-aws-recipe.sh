#!/bin/bash

set -euo pipefail

# CI deploys no AWS Recipes, so compile this one and check the wiring a deploy
# would otherwise catch. `extension aws` needs a bicepconfig.json, and the
# Recipe calls the Kubernetes Recipe as a module, so compile copies of both in
# a scratch directory.
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
PACK_PATH="$REPO_ROOT/recipe-packs/aws-eks/aws-eks.bicep"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/containers-aws-recipe-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/recipes"
cp -R "$TEST_DIR/../recipes/aws" "$TEST_DIR/../recipes/kubernetes" "$WORK_DIR/recipes/"
cat >"$WORK_DIR/bicepconfig.json" <<'JSON'
{
  "extensions": {
    "aws": "br:biceptypes.azurecr.io/aws:latest"
  }
}
JSON
TEMPLATE=$("$HOME/.rad/bin/bicep" build --stdout "$WORK_DIR/recipes/aws/bicep/aws-eks-containers.bicep")

# Pod Identity gives credentials only to pods that run as the associated
# service account, so the trust policy, the association, and the pod spec must
# all name the same one. A pod started before its association gets no
# credentials, so the Kubernetes resources wait for the association.
SA_REF="[variables('serviceAccountName')]"
jq -e --arg sa "$SA_REF" '
  .resources.kube.properties.parameters.serviceAccountName.value == $sa and
  .resources.association.properties.properties.ServiceAccount == $sa and
  .resources.role.properties.properties.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] == $sa and
  (.resources.kube.properties.template.resources.deployment.properties.spec.template.spec |
    contains("createObject(\u0027serviceAccountName\u0027, parameters(\u0027serviceAccountName\u0027))")) and
  .resources.kube.dependsOn == ["association"]
' <<<"$TEMPLATE" >/dev/null ||
    { echo "The pods must run as the service account of the Pod Identity association, after the association exists" >&2; exit 1; }

# The aws-eks pack must pass every required Recipe parameter and nothing the
# Recipe does not declare.
# shellcheck source=.github/scripts/lib-recipe-packs.sh
source "$REPO_ROOT/.github/scripts/lib-recipe-packs.sh"
rtc_check_recipe_pack_params "$PACK_PATH" "Radius.Compute/containers" "$TEMPLATE"

echo "AWS containers Recipe and pack parameter contract test passed"
