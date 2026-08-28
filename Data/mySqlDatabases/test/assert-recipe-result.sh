#!/bin/bash

set -euo pipefail

RECIPE_PATH="$(dirname "$0")/../recipes/kubernetes/bicep/kubernetes-mysql.bicep"
RESULT=$("$HOME/.rad/bin/bicep" build --stdout "$RECIPE_PATH" | jq '.outputs.result.value')

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
