#!/bin/bash

set -euo pipefail

# CI deploys no AWS Recipes, so compile this one to catch errors before
# publishing. `extension aws` needs a bicepconfig.json, and the Recipe calls the
# Kubernetes Recipe as a module, so compile copies of both in a scratch
# directory.
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
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
"$HOME/.rad/bin/bicep" build --stdout "$WORK_DIR/recipes/aws/bicep/aws-eks-containers.bicep" >/dev/null

echo "AWS containers Recipe compiled"
