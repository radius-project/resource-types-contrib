#!/bin/bash

# Deploys the AWS MySQL Recipe from this checkout into an Environment with no
# AWS account. Invalid database, username, and password values must fail in the
# Recipe, before any AWS call, and valid boundary values must pass the checks.
# Needs a Radius cluster with the local Recipe registry (make create-radius-cluster).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
RECIPE_PATH="$TEST_DIR/../recipes/aws/bicep/aws-rds-mysql.bicep"
REGISTRY="${RECIPE_REGISTRY:-localhost:5000}"
CLUSTER_REGISTRY="${RECIPE_CLUSTER_REGISTRY:-reciperegistry:5000}"
NAME="mysql-aws-input-checks"
CHECK_FAILED="Invalid Radius.Data/mySqlDatabases properties for Amazon RDS for MySQL"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${NAME}-XXXXXX")"
cleanup() {
    rad app delete "$NAME" --environment "$NAME" --yes >/dev/null 2>&1 || true
    rad env delete "$NAME" --yes >/dev/null 2>&1 || true
    rad resource delete Radius.Core/recipePacks "$NAME" --yes >/dev/null 2>&1 || true
    kubectl delete namespace "$NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cat >"$WORK_DIR/bicepconfig.json" <<'EOF'
{
  "extensions": {
    "radius": "br:biceptypes.azurecr.io/radius:latest",
    "aws": "br:biceptypes.azurecr.io/aws:latest"
  }
}
EOF
cp "$RECIPE_PATH" "$WORK_DIR/recipe.bicep"
cp "$TEST_DIR/aws-input-checks.bicep" "$WORK_DIR/app.bicep"
rad bicep publish --file "$WORK_DIR/recipe.bicep" --target "br:$REGISTRY/radius-recipes/$NAME:latest" --plain-http

cat >"$WORK_DIR/pack.bicep" <<EOF
extension radius

resource pack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: '$NAME'
  properties: {
    recipes: {
      'Radius.Data/mySqlDatabases': {
        kind: 'bicep'
        source: '$CLUSTER_REGISTRY/radius-recipes/$NAME:latest'
        plainHttp: true
        parameters: {
          eksClusterName: 'input-checks'
          subnetIds: 'subnet-0input,subnet-1checks'
        }
      }
    }
  }
}
EOF

kubectl create namespace "$NAME" >/dev/null
rad env create "$NAME" --kubernetes-namespace "$NAME"
rad deploy "$WORK_DIR/pack.bicep" --environment "$NAME"
rad env update "$NAME" --recipe-packs "$NAME"

# Deploys the app with the given values and prints the output. The deploy
# always fails: either a check rejects a value, or AWS isn't configured.
deploy() {
    jq -n --arg app "$NAME" --arg database "$1" --arg username "$2" --arg password "$3" '{
      "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
      contentVersion: "1.0.0.0",
      parameters: {
        applicationName: { value: $app },
        database: { value: $database },
        username: { value: $username },
        password: { value: $password }
      }
    }' >"$WORK_DIR/parameters.json"
    if rad deploy "$WORK_DIR/app.bicep" --environment "$NAME" --parameters "@$WORK_DIR/parameters.json" 2>&1; then
        echo "Deploy unexpectedly succeeded" >&2
        return 1
    fi
}

# Fails unless the output has every expected message and not the password.
expect_rejected() {
    local output="$1" password="$2" message
    shift 2
    for message in "$CHECK_FAILED" "No AWS resources were created" "$@"; do
        grep -qF -- "$message" <<<"$output" ||
            { echo "Expected '$message' in:" >&2; echo "$output" >&2; exit 1; }
    done
    if grep -qF -- "$password" <<<"$output"; then
        echo "The error output contains the password" >&2
        exit 1
    fi
}

password='Passw0rd@123'
output="$(deploy 'app-db' 'rdsadmin' "$password")"
expect_rejected "$output" "$password" \
    "database 'app-db' must be 1 to 64 characters" \
    "username 'rdsadmin' is a reserved word" \
    "password must be 8 to 41 printable ASCII characters"

long_username="$(printf 'a%.0s' {1..33})"
password='Passw0r'
output="$(deploy 'Select' "$long_username" "$password")"
expect_rejected "$output" "$password" \
    "database 'Select' is a reserved word" \
    "username '$long_username' must be 1 to 32 characters" \
    "password must be 8 to 41 printable ASCII characters"

password='Passw0rd 123'
output="$(deploy '1db' 'MySQL' "$password")"
expect_rejected "$output" "$password" \
    "database '1db' must be 1 to 64 characters" \
    "username 'MySQL' is a reserved word" \
    "password must be 8 to 41 printable ASCII characters"

# The longest values RDS accepts, and every password symbol it allows. These
# pass the checks and fail later because the Environment has no AWS account.
# Radius v0.62.0 reports the AWS resource types; later versions report the
# AWS extension scope.
database="a$(printf 'b%.0s' {1..61})_9"
username="U$(printf 'x%.0s' {1..30})_"
password="P'ss~!#\$%^&*()_+-={}[]|\\:;<>,.?\`abcdefghi"
output="$(deploy "$database" "$username" "$password")"
if grep -qF -- "$CHECK_FAILED" <<<"$output" || ! grep -qE 'AWS\.(EKS|RDS)/|/extensions/aws/' <<<"$output"; then
    echo "Valid values didn't reach the AWS resources:" >&2
    echo "$output" >&2
    exit 1
fi

echo "AWS MySQL Recipe input check test passed"
