#!/bin/bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
BICEP="$HOME/.rad/bin/bicep"
RECIPE_PATH="$TEST_DIR/../recipes/kubernetes/bicep/kubernetes-mysql.bicep"
RESULT=$("$BICEP" build --stdout "$RECIPE_PATH" | jq '.outputs.result.value')

jq -e '
  (has("secrets") | not) and
  (.values | keys | sort) == ["database", "host", "port"] and
  (.resources | length) == 3 and
  any(.resources[]; contains("/providers/core/Secret/")) and
  any(.resources[]; contains("/providers/core/Service/")) and
  any(.resources[]; contains("/providers/apps/Deployment/")) and
  ([.. | objects | keys[]] | index("username") == null) and
  ([.. | objects | keys[]] | index("password") == null) and
  ([.. | objects | keys[]] | index("connectionString") == null)
' <<<"$RESULT" >/dev/null

echo "MySQL Recipe result contract test passed"

# The AWS Recipe uses `extension aws`, which Bicep resolves through a
# bicepconfig.json next to the file, so compile a copy in a scratch directory.
AWS_RECIPE_PATH="$TEST_DIR/../recipes/aws/bicep/aws-rds-mysql.bicep"
AWS_PACK_PATH="$REPO_ROOT/recipe-packs/aws-eks/aws-eks.bicep"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mysql-aws-recipe-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
cp "$AWS_RECIPE_PATH" "$WORK_DIR/recipe.bicep"
cat >"$WORK_DIR/bicepconfig.json" <<'EOF'
{
  "extensions": {
    "aws": "br:biceptypes.azurecr.io/aws:latest"
  }
}
EOF
AWS_TEMPLATE=$("$BICEP" build --stdout "$WORK_DIR/recipe.bicep")

# Same connection values as the Kubernetes Recipe, and no credentials.
jq -e '
  .outputs.result.value |
  (has("secrets") | not) and
  (.values | keys | sort) == ["database", "host", "port"] and
  ([.. | objects | keys[]] | index("username") == null) and
  ([.. | objects | keys[]] | index("password") == null)
' <<<"$AWS_TEMPLATE" >/dev/null

# Check names by evaluating the Recipe for sample inputs, so the checks hold
# however the Bicep is written. Prints the AWS resources that a deploy would
# send, keyed by resource type.
aws_resources() {
    local cluster="$1" namespace="$2" resource_id="$3" version="$4"
    cat >"$WORK_DIR/recipe.bicepparam" <<EOF
using './recipe.bicep'
param context = {
  application: null
  environment: { id: '/planes/radius/local/resourceGroups/test/providers/Radius.Core/environments/test' }
  runtime: { kubernetes: { namespace: '$namespace' } }
  resource: {
    id: '$resource_id'
    name: 'db'
    properties: { username: 'admin1', password: 'Passw0rd123', version: '$version' }
  }
}
param eksClusterName = '$cluster'
param subnetIds = 'subnet-0abc,subnet-0def'
EOF
    # Command substitutions don't inherit set -e, so return on failure instead
    # of reading the previous sample's snapshot.
    rm -f "$WORK_DIR/recipe.snapshot.json"
    "$BICEP" snapshot "$WORK_DIR/recipe.bicepparam" --mode Overwrite >/dev/null || return 1
    jq -c '.predictedResources | map({key: (.type | sub("@.*$"; "")), value: .properties}) | from_entries' \
        "$WORK_DIR/recipe.snapshot.json"
}

# Prints the DB instance name after checking that the subnet group and the
# parameter group are named after it and that the DB instance uses both. The
# parameter group name ends with the version without the dot.
aws_name() {
    local resources name pg
    resources="$(aws_resources "$@")" || return 1
    name="$(jq -r '."AWS.RDS/DBInstance".properties.DBInstanceIdentifier' <<<"$resources")" || return 1
    pg="$name-${4//./}"
    if ! jq -e --arg name "$name" --arg pg "$pg" '
      (."AWS.RDS/DBInstance" | .alias == $name and .properties.DBSubnetGroupName == $name and .properties.DBParameterGroupName == $pg) and
      (."AWS.RDS/DBSubnetGroup" | .alias == $name and .properties.DBSubnetGroupName == $name) and
      (."AWS.RDS/DBParameterGroup" | .alias == $pg and .properties.DBParameterGroupName == $pg)
    ' <<<"$resources" >/dev/null; then
        echo "AWS MySQL Recipe must name the subnet group $name and the parameter group $pg, and the DB instance must use both" >&2
        return 1
    fi
    echo "$name"
}

ID=/planes/radius/local/resourceGroups/test/providers/Radius.Data/mySqlDatabases/db
name="$(aws_name cluster-a ns-a "$ID" 8.4)"

# A different name makes the next deploy create a new DB instance and leave
# the old one, so existing names must not change.
[[ "$name" == mysql-7vm536dxwdw5m ]] ||
    { echo "AWS MySQL Recipe names changed to $name, which would replace existing databases" >&2; exit 1; }

# Radius resource IDs repeat across installations, so names must also hash the
# cluster and the Environment's Kubernetes namespace. Cluster names and
# namespaces can contain `-`, so moving one across the boundary must change
# the name too.
expect_other_name() {
    local other
    other="$(aws_name "$1" "$2" "$3" 8.4)"
    [[ "$other" != "$name" ]] ||
        { echo "AWS MySQL Recipe names must hash the cluster, namespace, and resource ID: $* also gives $name" >&2; exit 1; }
}
expect_other_name cluster-b ns-a "$ID"
expect_other_name cluster-a ns-b "$ID"
expect_other_name cluster-a ns-a "${ID}2"
expect_other_name cluster a-ns-a "$ID"
expect_other_name cluster-a-ns a "$ID"

# AWS can't change a parameter group's family, so only the parameter group
# name includes the version, which aws_name checks.
name_80="$(aws_name cluster-a ns-a "$ID" 8.0)"
[[ "$name_80" == "$name" ]] ||
    { echo "AWS MySQL Recipe DB instance names must not depend on the version" >&2; exit 1; }

# The aws-eks pack must pass every required Recipe parameter and nothing the
# Recipe does not declare.
# shellcheck source=.github/scripts/lib-recipe-packs.sh
source "$REPO_ROOT/.github/scripts/lib-recipe-packs.sh"
AWS_PACK_TEMPLATE=$(rtc_build_recipe_pack "$AWS_PACK_PATH")
rtc_check_recipe_pack_params "$AWS_PACK_TEMPLATE" "Radius.Data/mySqlDatabases" "$AWS_TEMPLATE"

echo "AWS MySQL Recipe result and pack parameter contract test passed"
