#!/bin/bash
# ------------------------------------------------------------
# Copyright 2026 The Radius Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ------------------------------------------------------------

# Approved test tuples. L is excluded because the pack maps it to the M SKU.
# These variables are return values for callers that source this file.
# shellcheck disable=SC2034
rtc_postgres_test_tuple() {
    case "$1" in
        S) postgres_sku="Standard_B1ms"; postgres_tier="Burstable" ;;
        M) postgres_sku="Standard_D2ds_v5"; postgres_tier="GeneralPurpose" ;;
        *) echo "Error: PostgreSQL test size must be S or M." >&2; return 1 ;;
    esac
}

# Fail closed when a release overlay changes the tuple or required features.
rtc_validate_postgres_test_pack() {
    local pack="$1" entry small_sku small_tier setting wrapper sku_expression tier_expression
    entry="$(sed -n "/'Radius.Data\/postgreSqlDatabases': {/,/'Radius.Data\/sqlServerDatabases': {/p" "$pack")" || return 1
    rtc_postgres_test_tuple S
    small_sku="$postgres_sku"; small_tier="$postgres_tier"
    rtc_postgres_test_tuple M
    sku_expression="skuName: '{{context.resource.properties.size == \"S\" ? \"$small_sku\" : \"$postgres_sku\"}}'"
    tier_expression="tier: '{{context.resource.properties.size == \"S\" ? \"$small_tier\" : \"$postgres_tier\"}}'"
    # Keep direct-module checks for historical packs; current settings live in the wrapper.
    if grep -Fq "source: 'ghcr.io/radius-project/azure-aks-recipes/postgresqldatabases:" <<<"$entry"; then
        wrapper="${2:-$(dirname "$pack")/../../Data/postgreSqlDatabases/recipes/azure/bicep/azure-postgresql.bicep}"
        if [[ ! -f "$wrapper" ]] || ! grep -Fq "name: 'pgsql-{{context.azure.resourceNameHash}}'" <<<"$entry"; then
            echo "Error: PostgreSQL wrapper or stable server name is missing: $pack" >&2
            return 1
        fi
        entry="$(cat "$wrapper")" || return 1
        if ! grep -Fq "module server 'br/public:avm/res/db-for-postgre-sql/flexible-server:0.15.2'" <<<"$entry"; then
            echo "Error: PostgreSQL wrapper must retain the approved AVM version: $wrapper" >&2
            return 1
        fi
        sku_expression="skuName: (properties.?size ?? 'S') == 'S' ? '$small_sku' : '$postgres_sku'"
        tier_expression="tier: (properties.?size ?? 'S') == 'S' ? '$small_tier' : '$postgres_tier'"
    fi
    if ! grep -Fq "$sku_expression" <<<"$entry" ||
        ! grep -Fq "$tier_expression" <<<"$entry"; then
        echo "Error: PostgreSQL selection policy differs from the pack SKU or tier mapping: $pack" >&2
        return 1
    fi
    for setting in "version: '16'" "availabilityZone: -1" "highAvailability: 'Disabled'" \
        "geoRedundantBackup: 'Disabled'" "storageSizeGB: 32" "publicNetworkAccess: 'Enabled'" \
        "activeDirectoryAuth: 'Enabled'" "passwordAuth: 'Enabled'"; do
        if ! grep -Fq "$setting" <<<"$entry"; then
            echo "Error: PostgreSQL selection policy differs from pack setting $setting: $pack" >&2
            return 1
        fi
    done
}

rtc_postgres_positive_limit() {
    local value="$1" maximum="$2"
    [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]] && ((10#$value <= maximum))
}

rtc_postgres_catalog_result() {
    python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

AVAILABLE_STATUSES = {"available", "default", "enabled", "supported", "visible"}
RESTRICTED_STATUSES = {"disabled", "restricted", "unavailable"}


def is_restricted(item):
    status = item.get("status")
    reason = item.get("reason")
    restricted = item.get("restricted")
    if status is not None and not isinstance(status, str):
        raise ValueError("status")
    if reason is not None and not isinstance(reason, str):
        raise ValueError("reason")
    if restricted is not None:
        if not isinstance(restricted, str):
            raise ValueError("restricted")
        normalized_restriction = restricted.lower()
        if normalized_restriction not in {"enabled", "disabled"}:
            raise ValueError("restricted")
    else:
        normalized_restriction = None
    normalized = status.lower() if status is not None else None
    if normalized is not None and normalized not in AVAILABLE_STATUSES | RESTRICTED_STATUSES:
        raise ValueError("status")
    return (
        normalized_restriction == "enabled"
        or bool(reason)
        or normalized in RESTRICTED_STATUSES
    )


def objects(parent, key):
    items = parent[key]
    if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
        raise ValueError(key)
    return items


def named(items):
    if not all(isinstance(item.get("name"), str) for item in items):
        raise ValueError("name")
    return items


def classify(catalog, tier, sku):
    if not isinstance(catalog, list) or not all(isinstance(item, dict) for item in catalog):
        return "InvalidCatalog"
    if not catalog:
        return "RegionRestricted"
    region_restricted = False
    for root in catalog:
        region_restricted = is_restricted(root) or region_restricted
        if "supportedFeatures" in root:
            for feature in named(objects(root, "supportedFeatures")):
                if feature["name"] == "OfferRestricted":
                    if feature.get("status") == "Enabled":
                        region_restricted = True
                    elif feature.get("status") != "Disabled":
                        return "InvalidCatalog"
        versions = named(objects(root, "supportedServerVersions"))
        editions = named(objects(root, "supportedServerEditions"))
        if not versions and not editions:
            region_restricted = True
        for version in versions:
            is_restricted(version)
        for edition in editions:
            is_restricted(edition)
            for server_sku in named(objects(edition, "supportedServerSkus")):
                is_restricted(server_sku)
            for storage in named(objects(edition, "supportedStorageEditions")):
                is_restricted(storage)
                for size in objects(storage, "supportedStorageMb"):
                    if type(size.get("storageSizeMb")) is not int:
                        raise ValueError("storageSizeMb")
                    is_restricted(size)
    if region_restricted:
        return "RegionRestricted"
    roots = [
        root
        for root in catalog
        if any(
            item["name"] == "16" and not is_restricted(item)
            for item in root["supportedServerVersions"]
        )
    ]
    if not roots:
        return "UnsupportedVersion"
    editions = [
        edition
        for root in roots
        for edition in root["supportedServerEditions"]
        if edition["name"] == tier and not is_restricted(edition)
    ]
    if not editions:
        return "UnsupportedTier"
    editions = [
        edition
        for edition in editions
        if any(
            item["name"] == sku and not is_restricted(item)
            for item in edition["supportedServerSkus"]
        )
    ]
    if not editions:
        return "UnsupportedSku"
    if not any(
        size["storageSizeMb"] == 32768 and not is_restricted(size)
        for edition in editions
        for storage in edition["supportedStorageEditions"]
        if not is_restricted(storage)
        for size in storage["supportedStorageMb"]
    ):
        return "UnsupportedStorage"
    return ""


try:
    with open(sys.argv[1], encoding="utf-8") as source:
        result = classify(json.load(source), sys.argv[2], sys.argv[3])
except (json.JSONDecodeError, KeyError, TypeError, ValueError):
    result = "InvalidCatalog"
print(result)
PY
}

# Read Azure CLI codes, not words in an error message. Reject mixed failures.
rtc_postgres_error_codes() {
    local file="$1"
    if jq -e . "$file" >/dev/null 2>&1; then
        jq -r '.. | objects | .code? // empty |
            if type == "string" and test("^[A-Za-z][A-Za-z0-9]*$") then . else "UnknownError" end' "$file"
    else
        sed -nE 's/^(ERROR: )?\(([A-Za-z][A-Za-z0-9]*)\).*/\2/p' "$file"
    fi
}
