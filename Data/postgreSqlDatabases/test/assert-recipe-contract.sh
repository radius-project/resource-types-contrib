#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
BICEP="${BICEP_COMMAND:-$HOME/.rad/bin/bicep}"
"$BICEP" build "$ROOT/Data/postgreSqlDatabases/recipes/kubernetes/bicep/kubernetes-postgresql.bicep" --outfile "$TEMP/kubernetes.json"
"$BICEP" build "$ROOT/Data/postgreSqlDatabases/recipes/azure/bicep/azure-postgresql.bicep" --outfile "$TEMP/azure.json"
jq -e '
  (.outputs.result.value | has("secrets") | not) and
  (.outputs.result.value.values | keys | sort) == ["database","host","port"] and
  (.variables.tlsPolicy | contains("required")) and
  (.variables | map(select(type == "string")) | any(
    contains("hostssl all all all scram-sha-256") and
    contains("hostnossl all all all %s") and contains("ssl=off"))) and
  (.resources.tlsSecret.existing == true) and
  (.outputs.result.value.resources | contains("tlsSecret") | not) and
  (.resources.postgresql.properties.spec.template.metadata.annotations |
    contains("tlsEnabled") and contains("postgresqlTlsCertificateRevision"))
' "$TEMP/kubernetes.json" >/dev/null
jq -e '
  .parameters.tlsPolicy.allowedValues == ["required","optional"] and
  .parameters.administratorLoginPassword.type == "securestring" and
  (.outputs | keys) == ["fqdn"] and
  (.resources[0].name | contains("uniqueString(parameters('\''name'\''))")) and
  (.resources[0].properties.parameters.configurations.value ==
    "[parameters('\''configurations'\'')]")
' "$TEMP/azure.json" >/dev/null
echo "PostgreSQL compiled recipe contracts passed"
