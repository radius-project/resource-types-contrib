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

# Radius resource IDs repeat across installations, so AWS names must also hash
# the cluster and the Environment's Kubernetes namespace.
jq -e '
  (.variables.namespace | contains("runtime") and contains("kubernetes") and contains("namespace")) and
  (.variables.name | contains("eksClusterName") and contains("variables('"'"'namespace'"'"')") and contains(".resource.id"))
' <<<"$AWS_TEMPLATE" >/dev/null ||
    { echo "AWS MySQL Recipe names must hash the cluster, namespace, and resource ID" >&2; exit 1; }

# The aws-eks pack must pass every required Recipe parameter and nothing the
# Recipe does not declare: a deployment rejects undeclared parameters.
# shellcheck source=.github/scripts/lib-recipe-packs.sh
source "$REPO_ROOT/.github/scripts/lib-recipe-packs.sh"
PACK_PARAMS=$(
    rtc_recipe_pack_entry_body "$AWS_PACK_PATH" "Radius.Data/mySqlDatabases" |
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
  ($passed | length) > 0 and
  ($required - $passed) == [] and
  ($passed - ($params | keys)) == []
' <<<"$AWS_TEMPLATE" >/dev/null ||
    { echo "aws-eks pack parameters $PACK_PARAMS do not match the AWS MySQL Recipe parameters" >&2; exit 1; }

echo "AWS MySQL Recipe result and pack parameter contract test passed"
