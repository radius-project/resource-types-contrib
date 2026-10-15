#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TEMPLATE=$("$HOME/.rad/bin/bicep" build --stdout "$ROOT/Data/postgreSqlDatabases/recipes/azure/bicep/azure-postgresql.bicep")
jq -e '
  (.parameters | keys == ["context", "postgreSqlServerConfigurations"]) and
  (.parameters.context.type == "secureObject") and
  (.parameters.postgreSqlServerConfigurations.defaultValue == []) and
  (.variables.requestedTls | contains("tryGet") and contains("required")) and
  (.variables.serverName | contains("required") and contains("optional") and
    contains("resourceNameHash") and contains("pgsql-") and
    contains("fail(") and contains("disabled is Kubernetes-only")) and
  (.resources[0].properties.parameters.name.value == "[variables('\''serverName'\'')]") and
  (.resources[0].properties.parameters.configurations.value | contains("operatorSetsTransport")) and
  (.variables.operatorSetsTransport | contains("require_secure_transport") and contains("equals(")) and
  (.resources[0].properties.parameters.version.value == "16") and
  (.resources[0].properties.parameters.storageSizeGB.value == 32) and
  (.resources[0].properties.parameters.publicNetworkAccess.value == "Enabled") and
  (.resources[0].properties.parameters.firewallRules.value ==
    [{name:"allow-all", startIpAddress:"0.0.0.0", endIpAddress:"255.255.255.255"}]) and
  (.outputs | keys == ["result"]) and
  (.outputs.result.value | keys == ["resources", "values"]) and
  (.outputs.result.value.resources | length == 1) and
  (.outputs.result.value.resources[0] | contains("outputs.resourceId.value") and (contains("/planes/") | not)) and
  (.outputs.result.value.values | keys == ["host"]) and
  (.outputs.result.value.values.host | contains("tryGet(") and contains("fqdn") and contains("fail("))
' <<<"$TEMPLATE" >/dev/null
grep -Fq 'flexible-server:0.15.2' "$ROOT/Data/postgreSqlDatabases/recipes/azure/bicep/azure-postgresql.bicep"
echo "Azure PostgreSQL compiled guard/input/result contract passed (not live migration proof)"
