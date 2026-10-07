#!/bin/bash
set -euo pipefail

RECIPE_PATH="$(dirname "$0")/../recipes/kubernetes/bicep/kubernetes-postgresql.bicep"
TEMPLATE=$("$HOME/.rad/bin/bicep" build --stdout "$RECIPE_PATH")

jq -e '
  (.outputs.result.value | has("secrets") | not) and
  (.outputs.result.value.values | keys | sort) == ["database", "host", "port"] and
  (.outputs.result.value.resources | contains("transportConfig")) and
  (.outputs.result.value.resources | contains("initSqlConfigMap")) and
  (.outputs.result.value | tostring | contains("tls.key") | not) and
  (.variables.requestedTls | contains("tryGet")) and
  (.variables.requestedTls | contains("required")) and
  (.variables.hbaRequiredConfig | contains("hostnossl all all 0.0.0.0/0 reject")) and
  (.variables.hbaRequiredConfig | contains("hostnossl all all ::/0 reject")) and
  (.variables.hbaRequiredConfig | contains("hostssl all all ::/0 scram-sha-256")) and
  (.variables.hbaOptionalConfig | contains("scram-sha-256")) and
  (.parameters.postgresqlTlsSecretName.defaultValue == "") and
  (.parameters.postgresqlTlsSecretName | has("minLength") | not) and
  (.parameters.postgresqlTlsCertificateRevision.minLength == 1) and
  (.variables.tlsSecretName | contains("empty(parameters")) and
  (.variables.tlsSecretName | contains("-tls")) and
  (.resources.transportConfig.properties.data | keys | sort) == ["pg_hba-optional.conf", "pg_hba-required.conf"] and
  (.resources.postgresql.properties.spec.strategy.type == "RollingUpdate") and
  (.resources.postgresql.properties.spec.strategy.rollingUpdate.maxSurge == 0) and
  (.resources.postgresql.properties.spec.strategy.rollingUpdate.maxUnavailable == 1) and
  (.resources.postgresql.properties.spec.template.metadata.annotations | keys | sort) ==
    ["radapp.io/postgresql-tls-policy", "radapp.io/postgresql-tls-revision"] and
  (.resources.postgresql.properties.spec.template.spec.containers[0].readinessProbe.exec.command ==
    ["pg_isready", "-q", "-h", "127.0.0.1"]) and
  (.resources.postgresql.properties.spec.template.spec.volumes | tostring |
    contains("tlsSecretName")) and
  (.resources.postgresql.properties.spec.template.spec.containers[0].args |
    index("ssl=on") != null and
    any(.[]; contains("hba_file=/transport/pg_hba-")) and
    index("ssl_key_file=/tls/server.key") != null and
    index("password_encryption=scram-sha-256") != null) and
  (.resources.postgresql.properties.spec.template.spec.initContainers[0].command[2] |
    contains("chmod 600 /tls/server.key") and contains("chown -R postgres:postgres /tls"))
' <<<"$TEMPLATE" >/dev/null

echo "PostgreSQL Bicep transport and output contract checks passed"
