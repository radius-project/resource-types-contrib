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

# Transport policy contract (Kubernetes).
#
# The deployment test only proves that a default-configured client can connect,
# and such a client negotiates TLS opportunistically. It therefore passes
# whether or not the Recipe enforces anything, so it provides no regression
# protection for the `tls` property. Assert the enforcement statically instead.
#
# Each link in the chain is checked, not just its endpoints: `tls` must read the
# property and fall back to the secure value, `requireSecureTransport` must
# derive from `tls` without inverting the mapping, and the `mysqld` flag must
# take its value from that variable. Asserting only that the flag is present
# would still pass if someone hardcoded `--require-secure-transport=OFF`.
jq -e '
  (.variables.tls | contains("tls") and contains("required")) and
  (.variables.requireSecureTransport
     | contains("variables(") and contains("tls") and test("optional.*OFF.*ON")) and
  ([.resources.mySql.properties.spec.template.spec.containers[]
      | (.args // [])[]
      | select(contains("--require-secure-transport="))] as $flags
   | ($flags | length) == 1
     and ($flags[0] | contains("requireSecureTransport")))
' <<<"$TEMPLATE" >/dev/null

echo "MySQL Kubernetes Recipe transport policy test passed"

# Transport policy contract (AWS).
#
# CI never provisions AWS, so the Terraform Recipe has no deployment coverage.
# Check the same chain statically. This proves the Recipe declares the parameter
# and derives it correctly; it does not prove RDS accepts or applies it.
AWS_RECIPE="$(dirname "$0")/../recipes/aws/terraform/main.tf"
AWS_NORMALIZED=$(sed -e 's|#.*||' -e 's|//.*||' "$AWS_RECIPE" | tr -s '[:space:]' ' ')

for pattern in \
  'tls = try\(var\.context\.resource\.properties\.tls, "required"\)' \
  'require_secure_transport = local\.tls == "optional" \? "OFF" : "ON"' \
  'name = "require_secure_transport" value = local\.require_secure_transport'
do
  if ! grep -Eq "$pattern" <<<"$AWS_NORMALIZED"; then
    echo "AWS Recipe transport policy test failed: no match for /$pattern/" >&2
    exit 1
  fi
done

echo "MySQL AWS Recipe transport policy test passed"
