#!/bin/bash

set -euo pipefail

RECIPE_PATH="$(dirname "$0")/../recipes/kubernetes/bicep/kubernetes-mysql.bicep"
TEMPLATE=$("$HOME/.rad/bin/bicep" build --stdout "$RECIPE_PATH")
RESULT=$(jq '.outputs.result.value' <<<"$TEMPLATE")

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

# Transport policy contract.
#
# The deployment test only proves that a default-configured client can connect,
# and such a client negotiates TLS opportunistically. It therefore passes
# whether or not the Recipe enforces anything, so it provides no regression
# protection for the `tls` property. Assert the enforcement statically instead:
# the `mysqld` flag must be present, the secure value must be the fallback when
# the property is absent, and the mapping must not be inverted.
jq -e '
  (.variables.tls | contains("required")) and
  (.variables.requireSecureTransport | test("optional.*OFF.*ON")) and
  any(.resources.mySql.properties.spec.template.spec.containers[];
      .args // [] | any(contains("--require-secure-transport=")))
' <<<"$TEMPLATE" >/dev/null

echo "MySQL Recipe transport policy test passed"
