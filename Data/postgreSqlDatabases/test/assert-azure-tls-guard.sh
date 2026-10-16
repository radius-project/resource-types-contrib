#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
umask 077
BICEP="${BICEP_COMMAND:-$HOME/.rad/bin/bicep}"
"$BICEP" build "$ROOT/Data/postgreSqlDatabases/recipes/azure/bicep/azure-postgresql.bicep" \
    --outfile "$TEMP/azure.json"

# Run against the isolated Kubernetes test environment, without Azure credentials.
for override in none ON OFF; do
    jq -n --arg override "$override" '{
      tlsPolicy:"disabled",name:"tls-validation-only",administratorLogin:"fixture",
      administratorLoginPassword:"Fixture-Only-Password-337!",authConfig:{},
      skuName:"Standard_B1ms",tier:"Burstable",databases:[],version:"16",
      availabilityZone:-1,highAvailability:"Disabled",geoRedundantBackup:"Disabled",
      storageSizeGB:32,publicNetworkAccess:"Disabled",firewallRules:[],
      enableAdvancedThreatProtection:false,enableTelemetry:false,lock:{},
      configurations:(if $override == "none" then [] else
        [{name:"require_secure_transport",value:$override}] end)
    } | {parameters:map_values({value:.})}' > "$TEMP/parameters.json"
    if RADIUS_PREVIEW=true timeout 90 rad deploy "$TEMP/azure.json" -p "@$TEMP/parameters.json" \
        > "$TEMP/output" 2>&1; then
        echo "Error: Azure accepted disabled with override=$override." >&2
        exit 1
    fi
    if ! grep -Fq "template parameter 'tlsPolicy' is not valid" "$TEMP/output" ||
       ! grep -Fq "value 'disabled' is not part of the allowed value(s)" "$TEMP/output"; then
        echo "Error: Azure failed for a reason other than the TLS guard (override=$override)." >&2
        cat "$TEMP/output" >&2
        exit 1
    fi
done
echo "Azure rejects disabled before deployment, including ON and OFF overrides"
